//
//  ImageSource.swift
//  Photo Editor
//
//  Decoding for the three kinds of file this app opens: Apple ProRAW / DNG,
//  HEIC and JPEG.
//
//  Raw files go through CIRAWFilter with Apple's own rendering turned off
//  (`boostAmount = 0`, no local tone mapping, no sharpening), which yields a
//  linear scene-referred image. That's the same starting point Camera Raw
//  works from, and it's what lets the Adobe parameters behave as expected.
//  Rendered files already carry a baked-in tone curve, so they skip that step.
//

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

nonisolated final class ImageSource: @unchecked Sendable {

    private static let log = Logger(subsystem: "henril.Photo-Editor", category: "ImageSource")

    enum Content {
        case url(URL)
        case data(Data, typeIdentifier: String?)
    }

    let content: Content
    let displayName: String
    let isRaw: Bool
    let nativeSize: CGSize

    /// The camera's own white balance, used as the neutral point for the
    /// Temp / Tint sliders on raw files.
    let asShotTemperature: Double
    let asShotTint: Double

    /// The type actually decoded, determined from the file's own bytes where
    /// possible rather than from whatever the picker claimed.
    let resolvedType: UTType?

    /// True for Apple ProRAW. Those DNGs embed Apple's own profile and
    /// CIRAWFilter applies it; every other raw gets a generic, much flatter
    /// rendering that needs a base curve to match Lightroom.
    let isAppleRaw: Bool

    /// Short label for the format badge — "RAW", "HEIC", "JPEG".
    var formatLabel: String {
        if isRaw { return "RAW" }
        if let resolvedType {
            if resolvedType.conforms(to: .heic) || resolvedType.identifier.contains("heif") {
                return "HEIC"
            }
            if resolvedType.conforms(to: .jpeg) { return "JPEG" }
            if resolvedType.conforms(to: .png) { return "PNG" }
            if resolvedType.conforms(to: .tiff) { return "TIFF" }
            if let ext = resolvedType.preferredFilenameExtension { return ext.uppercased() }
        }
        let ext = (displayName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "IMAGE" : ext.uppercased()
    }

    /// Megapixels, for the badge's detail line.
    var megapixels: Double {
        nativeSize.width * nativeSize.height / 1_000_000
    }

    // MARK: - Creation

    init?(url: URL) {
        self.content = .url(url)
        self.displayName = url.lastPathComponent

        let sniffed = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceGetType($0) as String? }
            .flatMap { UTType($0) }
        let type = sniffed ?? UTType(filenameExtension: url.pathExtension)
        self.resolvedType = type
        self.isRaw = Self.isRawType(type, fileExtension: url.pathExtension)
        self.isAppleRaw = isRaw && Self.isApple(
            CGImageSourceCreateWithURL(url as CFURL, nil)
        )

        if isRaw, let filter = CIRAWFilter(imageURL: url) {
            nativeSize = filter.nativeSize
            asShotTemperature = Double(filter.neutralTemperature)
            asShotTint = Double(filter.neutralTint)
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            nativeSize = Self.pixelSize(from: source)
            asShotTemperature = 5500
            asShotTint = 0
        } else {
            return nil
        }
    }

    init?(data: Data, name: String, typeIdentifier: String?) {
        self.content = .data(data, typeIdentifier: typeIdentifier)
        self.displayName = name

        // Trust the bytes over the declared type. The Photos picker lists its
        // content types in compatibility order, so the first one is often
        // `public.jpeg` even when the payload is something else entirely —
        // believing it would mislabel every file and skip the raw path.
        let sniffed = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetType($0) as String? }
            .flatMap { UTType($0) }
        let type = sniffed ?? typeIdentifier.flatMap { UTType($0) }
        self.resolvedType = type
        self.isRaw = Self.isRawType(type, fileExtension: (name as NSString).pathExtension)
        self.isAppleRaw = isRaw && Self.isApple(
            CGImageSourceCreateWithData(data as CFData, nil)
        )

        if isRaw, let filter = CIRAWFilter(imageData: data, identifierHint: typeIdentifier) {
            nativeSize = filter.nativeSize
            asShotTemperature = Double(filter.neutralTemperature)
            asShotTint = Double(filter.neutralTint)
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            nativeSize = Self.pixelSize(from: source)
            asShotTemperature = 5500
            asShotTint = 0
        } else {
            return nil
        }
    }

    private static func isRawType(_ type: UTType?, fileExtension: String) -> Bool {
        if let type, type.conforms(to: .rawImage) { return true }
        let rawExtensions: Set<String> = [
            "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
            "raf", "orf", "rw2", "pef", "srw", "erf", "dcr", "3fr", "iiq",
        ]
        return rawExtensions.contains(fileExtension.lowercased())
    }

    /// Reads the EXIF camera make.
    private static func isApple(_ source: CGImageSource?) -> Bool {
        guard let source,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let make = tiff[kCGImagePropertyTIFFMake] as? String
        else { return false }
        return make.localizedCaseInsensitiveContains("Apple")
    }

    private static func pixelSize(from source: CGImageSource) -> CGSize {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .zero }

        let width = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0

        // Orientations 5–8 swap the axes.
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - Decoding

    /// The linear input to the adjustment pipeline.
    ///
    /// - Parameters:
    ///   - settings: Only the white balance and noise reduction values are used
    ///     here; for raw those are far more accurate applied at demosaic time.
    ///   - maxDimension: Long-edge limit. Previews render small so the pipeline
    ///     stays interactive; export passes `nil` for full resolution.
    ///   - draft: Enables CIRAWFilter's faster, lower-quality demosaic.
    func makeBaseImage(
        settings: EditSettings,
        maxDimension: CGFloat?,
        draft: Bool
    ) -> CIImage? {
        isRaw
            ? makeRawImage(settings: settings, maxDimension: maxDimension, draft: draft)
            : makeRenderedImage(maxDimension: maxDimension)
    }

    /// The white point a raw decode will actually use for these settings.
    ///
    /// The preview renderer needs this to work out how far a cached decode is
    /// from the white balance now being asked for, so it can adapt the cached
    /// pixels instead of demosaicing all over again.
    func decodeWhiteBalance(for settings: EditSettings) -> (kelvin: Double, tint: Double) {
        guard isRaw, settings.whiteBalanceMode != .asShot else {
            return (asShotTemperature, asShotTint)
        }
        if let fixed = settings.whiteBalanceMode.fixedTemperature {
            return (fixed.temp, fixed.tint)
        }
        if settings.isRawTemperature, settings.temperature > 0 {
            return (
                settings.temperature.clamped(to: 2000...50000),
                settings.tint.clamped(to: -150...150)
            )
        }
        if !settings.isRawTemperature, settings.temperature != 0 {
            // A relative value authored against a rendered file, applied
            // around this camera's own white point.
            return (
                (asShotTemperature * exp(settings.temperature / 100 * 0.55))
                    .clamped(to: 2000...50000),
                (asShotTint + settings.tint).clamped(to: -150...150)
            )
        }
        // "Custom" with no absolute temperature — the common case for a preset
        // that only carries an IncrementalTemperature shift. Keep the camera's
        // own white point; the relative shift is applied after demosaic.
        //
        // Getting this wrong is expensive: treating the absent value as 0 and
        // clamping it into the Kelvin range decodes at 2000 K and floods the
        // whole image cyan.
        return (asShotTemperature, asShotTint)
    }

    private func makeRawFilter() -> CIRAWFilter? {
        switch content {
        case .url(let url):
            return CIRAWFilter(imageURL: url)
        case .data(let data, let hint):
            return CIRAWFilter(imageData: data, identifierHint: hint)
        }
    }

    private func makeRawImage(
        settings: EditSettings,
        maxDimension: CGFloat?,
        draft: Bool
    ) -> CIImage? {
        guard let filter = makeRawFilter() else {
            Self.log.error("CIRAWFilter could not open \(self.displayName, privacy: .public)")
            return nil
        }

        switch settings.rawRendering {
        case .cameraMatch:
            // Leave the camera's rendering intact. For Apple ProRAW that's the
            // embedded profile with Smart HDR tone mapping, which is exactly
            // what Lightroom shows. Only sharpening is suppressed, so the
            // Detail panel isn't sharpening on top of it.
            filter.sharpnessAmount = 0

        case .neutral:
            // Strip Apple's rendering for linear sensor data. Flatter, but
            // nothing is tone-mapped yet, so the tone controls have full range.
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            filter.localToneMapAmount = 0
            filter.sharpnessAmount = 0
            filter.detailAmount = 0
            filter.contrastAmount = 0
            filter.extendedDynamicRangeAmount = 0
            filter.isGamutMappingEnabled = false
        }

        // Demosaic-time noise reduction genuinely outperforms anything we can
        // do downstream, so these two sliders are handled here rather than in
        // a kernel.
        filter.luminanceNoiseReductionAmount = Float((settings.luminanceNR / 100).clamped(to: 0...1))
        filter.colorNoiseReductionAmount = Float((settings.colorNR / 100).clamped(to: 0...1))

        // Camera-referred white balance, using the DNG's own colour matrices.
        // Single source of truth with the preview renderer, which needs to
        // know the same answer to decide whether a cached decode can be reused.
        let whiteBalance = decodeWhiteBalance(for: settings)
        filter.neutralTemperature = Float(whiteBalance.kelvin)
        filter.neutralTint = Float(whiteBalance.tint)

        filter.isDraftModeEnabled = draft
        if let maxDimension {
            let longEdge = max(nativeSize.width, nativeSize.height)
            if longEdge > 0 {
                filter.scaleFactor = Float(min(1.0, maxDimension / longEdge))
            }
        }

        guard let decoded = filter.outputImage else { return nil }
        return applyBaseRendering(to: decoded, settings: settings)
    }

    /// The base curve that turns the decode into a usable starting point.
    /// Apple ProRAW needs none — CIRAWFilter has already applied Apple's
    /// embedded profile, which is what Lightroom shows too.
    private func applyBaseRendering(to image: CIImage, settings: EditSettings) -> CIImage {
        switch settings.rawRendering {
        case .neutral:
            return BaseRenderingCurves.apply(BaseRenderingCurves.neutral, to: image)
        case .cameraMatch:
            return isAppleRaw
                ? image
                : BaseRenderingCurves.apply(BaseRenderingCurves.adobeMatch, to: image)
        }
    }

    private func makeRenderedImage(maxDimension: CGFloat?) -> CIImage? {
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]

        let image: CIImage?
        switch content {
        case .url(let url):
            image = CIImage(contentsOf: url, options: options)
        case .data(let data, _):
            image = CIImage(data: data, options: options)
        }

        guard var result = image else {
            Self.log.error("Could not decode \(self.displayName, privacy: .public)")
            return nil
        }

        if let maxDimension {
            let longEdge = max(result.extent.width, result.extent.height)
            if longEdge > maxDimension, longEdge > 0 {
                let scale = maxDimension / longEdge
                result = result.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: 1.0,
                ])
            }
        }

        return result
    }
}
