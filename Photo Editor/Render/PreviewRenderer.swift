//
//  PreviewRenderer.swift
//  Photo Editor
//
//  Serialises rendering off the main actor and caches the expensive part.
//
//  Demosaicing a 48-megapixel ProRAW file is by far the costliest step, and it
//  only depends on white balance, noise reduction and output size — none of
//  which move while you're dragging an Exposure slider. So the decoded result
//  is baked into a texture once and every subsequent adjustment runs against
//  that instead.
//

import CoreGraphics
import CoreImage
import Foundation
import simd

actor PreviewRenderer {

    private let engine = RenderEngine.shared
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// The inputs that force a re-decode. Everything else is applied on top of
    /// the cached base.
    private struct BaseKey: Equatable {
        let source: ObjectIdentifier
        let longEdge: CGFloat
        let draft: Bool
        let whiteBalanceMode: WhiteBalanceMode
        let temperature: Double
        let tint: Double
        let isRawTemperature: Bool
        let luminanceNR: Double
        let colorNR: Double
        let rawRendering: RawRendering

        /// The parts a cached decode can't be adapted around.
        ///
        /// White balance is excluded because it can be applied downstream as a
        /// matrix, and noise reduction because it's a refinement rather than a
        /// change of subject — presets vary `LuminanceSmoothing` constantly, and
        /// letting that invalidate the decode means a ~950ms re-demosaic every
        /// time one is applied. Both are picked up by the refine pass instead.
        var decodeIdentity: [AnyHashable] {
            [source, longEdge, draft, rawRendering]
        }

        init(source: ImageSource, settings: EditSettings, longEdge: CGFloat, draft: Bool) {
            self.source = ObjectIdentifier(source)
            self.longEdge = longEdge
            self.draft = draft
            self.whiteBalanceMode = settings.whiteBalanceMode
            self.temperature = settings.temperature
            self.tint = settings.tint
            self.isRawTemperature = settings.isRawTemperature
            // Only raw uses these at decode time.
            self.luminanceNR = source.isRaw ? settings.luminanceNR : 0
            self.colorNR = source.isRaw ? settings.colorNR : 0
            self.rawRendering = settings.rawRendering
        }
    }

    // One entry per output size, so the 2048px preview and the 320px browser
    // thumbnails don't evict each other on every scroll.
    private var cache: [CGFloat: (key: BaseKey, image: CIImage, whiteBalance: (kelvin: Double, tint: Double))] = [:]

    // MARK: - Preview

    /// Renders the interactive preview.
    ///
    /// - Parameter allowReDecode: When false, a white balance change is served
    ///   by adapting the cached decode rather than demosaicing again. That
    ///   turns a ~950ms Temp drag on a 48MP raw file into a ~50ms one, at the
    ///   cost of applying the shift after demosaic instead of during it. Pass
    ///   true once the drag settles to get the camera-referred result back.
    func preview(
        source: ImageSource,
        settings: EditSettings,
        longEdge: CGFloat = RenderEngine.previewLongEdge,
        allowReDecode: Bool = true
    ) -> CGImage? {
        let wanted = BaseKey(source: source, settings: settings, longEdge: longEdge, draft: true)

        // Reuse whatever decode we already have whenever it can be adapted to
        // what's being asked for. This is what makes applying a preset feel
        // instant even when it changes white balance or noise reduction.
        if !allowReDecode, source.isRaw,
           let cached = cache[longEdge],
           cached.key.decodeIdentity == wanted.decodeIdentity {

            let processed = engine.process(
                cached.image,
                settings: settings,
                isRaw: true,
                residualWhiteBalance: residualMatrix(
                    from: cached.whiteBalance,
                    to: source.decodeWhiteBalance(for: settings)
                )
            )
            return engine.makeCGImage(processed)
        }

        guard let base = base(for: source, settings: settings, longEdge: longEdge, draft: true)
        else { return nil }

        let processed = engine.process(base, settings: settings, isRaw: source.isRaw)
        return engine.makeCGImage(processed)
    }

    /// The unedited image, for the before/after comparison. Raw still gets the
    /// camera profile base curve — "before" means before *your* edits, not
    /// before any rendering at all, which is also what Lightroom shows.
    /// - Parameter settings: The state the photo opened in. Passing it rather
    ///   than a blank EditSettings keeps this on the same cache key as the
    ///   first preview, so opening a raw file costs one decode instead of two.
    func original(
        source: ImageSource,
        settings: EditSettings,
        longEdge: CGFloat = RenderEngine.previewLongEdge
    ) -> CGImage? {
        guard let base = base(for: source, settings: settings, longEdge: longEdge, draft: true)
        else { return nil }

        let processed = engine.process(base, settings: settings, isRaw: source.isRaw)
        return engine.makeCGImage(processed)
    }

    /// A small render used for the preset browser's live thumbnails.
    func thumbnail(
        source: ImageSource,
        settings: EditSettings,
        longEdge: CGFloat = RenderEngine.thumbnailLongEdge
    ) -> CGImage? {
        // Every preset shares one decode. The decode is pinned to the photo's
        // own white balance and default noise reduction, and each preset's
        // white balance is applied afterwards as a matrix — otherwise browsing
        // 450 presets would mean 450 re-demosaics of a 48-megapixel file.
        // Noise reduction is invisible at this size anyway.
        var pinned = EditSettings()
        pinned.isRawTemperature = source.isRaw
        pinned.colorNR = source.isRaw ? 25 : 0
        pinned.rawRendering = settings.rawRendering

        guard let base = base(for: source, settings: pinned, longEdge: longEdge, draft: true)
        else { return nil }

        let processed = engine.process(
            base,
            settings: settings,
            isRaw: source.isRaw,
            residualWhiteBalance: source.isRaw
                ? residualMatrix(
                    from: source.decodeWhiteBalance(for: pinned),
                    to: source.decodeWhiteBalance(for: settings)
                )
                : nil
        )
        return engine.makeCGImage(processed)
    }

    // MARK: - Export

    /// Full-resolution render with draft mode off.
    func export(
        source: ImageSource,
        settings: EditSettings,
        format: ExportFormat,
        quality: Double,
        colorSpace: CGColorSpace
    ) -> Data? {
        guard let base = source.makeBaseImage(
            settings: settings,
            maxDimension: nil,
            draft: false
        ) else { return nil }

        let processed = engine.process(base, settings: settings, isRaw: source.isRaw)
        return engine.encode(processed, as: format, quality: quality, colorSpace: colorSpace)
    }

    func invalidate() {
        cache.removeAll()
    }

    // MARK: - Base caching

    private func base(
        for source: ImageSource,
        settings: EditSettings,
        longEdge: CGFloat,
        draft: Bool
    ) -> CIImage? {
        let key = BaseKey(source: source, settings: settings, longEdge: longEdge, draft: draft)
        if let cached = cache[longEdge], cached.key == key { return cached.image }

        guard let decoded = source.makeBaseImage(
            settings: settings,
            maxDimension: longEdge,
            draft: draft
        ) else { return nil }

        let baked = source.isRaw ? bake(decoded) : decoded
        cache[longEdge] = (
            key: key,
            image: baked,
            whiteBalance: source.decodeWhiteBalance(for: settings)
        )
        return baked
    }

    /// Adaptation from the white point a cached decode was taken at to the one
    /// now wanted. Nil when they already match.
    private func residualMatrix(
        from have: (kelvin: Double, tint: Double),
        to wanted: (kelvin: Double, tint: Double)
    ) -> simd_float3x3? {
        guard have != wanted else { return nil }
        return ColorScience.whiteBalanceMatrix(
            kelvin: wanted.kelvin,
            tint: wanted.tint,
            baselineKelvin: have.kelvin,
            baselineTint: have.tint
        )
    }

    /// Flattens a lazily-evaluated CIImage into a real texture so the decode
    /// doesn't re-run on every frame. Half-float in a linear space keeps the
    /// highlight headroom that makes exposure recovery possible.
    private func bake(_ image: CIImage) -> CIImage {
        guard image.extent.isRenderable,
              let cg = engine.context.createCGImage(
                image,
                from: image.extent,
                format: .RGBAh,
                colorSpace: linearSpace
              )
        else { return image }

        return CIImage(cgImage: cg, options: [.colorSpace: linearSpace])
    }
}
