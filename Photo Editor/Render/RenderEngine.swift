//
//  RenderEngine.swift
//  Photo Editor
//
//  Assembles the Core Image graph for one set of edit settings.
//
//  Stage order follows Camera Raw's own processing pipeline rather than the
//  order the panels appear in the UI:
//
//    profile base curve (raw only)
//      → white balance → exposure
//      → basic tone (contrast, highlights, shadows, whites, blacks)
//      → tone curve (parametric + point + per-channel)
//      → colour mixer / B&W, vibrance, saturation
//      → colour grading
//      → dehaze → clarity → texture
//      → sharpening → colour noise reduction
//      → lens + post-crop vignette → grain
//
//  Getting this order wrong is the usual reason a faithful-looking parameter
//  set still renders differently to Lightroom, so it's worth keeping.
//

import CoreImage
import CoreGraphics
import Foundation
import Metal
import simd

nonisolated final class RenderEngine: @unchecked Sendable {

    static let shared = RenderEngine()

    let context: CIContext
    private let kernels = CIKernelLibrary.shared

    /// Long-edge size the interactive preview renders at. Large enough to
    /// judge grain and sharpening, small enough to stay responsive on a
    /// 48-megapixel ProRAW file.
    static let previewLongEdge: CGFloat = 2048
    static let thumbnailLongEdge: CGFloat = 320

    /// Blur radii are expressed relative to this long edge so that a preview
    /// and a full-resolution export produce the same look.
    private static let referenceLongEdge: CGFloat = 2048

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private init() {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .highQualityDownsample: true,
        ]

        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    // MARK: - Main entry point

    /// Applies `settings` to an already-decoded linear image.
    ///
    /// - Parameter residualWhiteBalance: An extra adaptation folded into the
    ///   white balance stage, used when the decoded input was demosaiced at a
    ///   different white point than the one being asked for. Lets the preview
    ///   follow a Temp drag on a raw file without re-decoding it.
    func process(
        _ input: CIImage,
        settings: EditSettings,
        isRaw: Bool,
        residualWhiteBalance: simd_float3x3? = nil
    ) -> CIImage {
        let extent = input.extent
        guard extent.isRenderable else { return input }

        let longEdge = max(extent.width, extent.height)
        let scale = longEdge / Self.referenceLongEdge

        var image = input

        image = applyWhiteBalanceAndExposure(
            image, settings: settings, isRaw: isRaw, residual: residualWhiteBalance
        )
        image = applyBasicTone(image, settings: settings)
        image = applyToneCurves(image, settings: settings)
        image = applyColorMixer(image, settings: settings)
        image = applyColorGrading(image, settings: settings)
        image = applyDehaze(image, settings: settings, scale: scale, extent: extent)
        image = applyClarityTexture(image, settings: settings, scale: scale, extent: extent)
        image = applySharpening(image, settings: settings, scale: scale, extent: extent)
        image = applyColorNoiseReduction(image, settings: settings, isRaw: isRaw, scale: scale, extent: extent)
        image = applyVignettes(image, settings: settings, extent: extent)
        image = applyGrain(image, settings: settings, scale: scale, extent: extent)

        return image.cropped(to: extent)
    }

    // MARK: - Stages

    private func applyWhiteBalanceAndExposure(
        _ image: CIImage,
        settings: EditSettings,
        isRaw: Bool,
        residual: simd_float3x3?
    ) -> CIImage {
        let gain = Float(pow(2.0, settings.exposure))

        var matrix = matrix_identity_float3x3

        // Correction for a cached decode taken at a different white point.
        if let residual { matrix = residual * matrix }

        // Absolute white balance. On raw this already happened at demosaic
        // time against the DNG's own colour matrices, which is more accurate
        // than anything we can do here, so only rendered files need it.
        if !isRaw, settings.whiteBalanceMode != .asShot,
           settings.temperature != 0 || settings.tint != 0 {
            let kelvin = settings.isRawTemperature
                ? settings.temperature
                : ColorScience.kelvinForRelative(settings.temperature)
            matrix = ColorScience.whiteBalanceMatrix(kelvin: kelvin, tint: settings.tint) * matrix
        }

        // The relative shift applies to raw and rendered alike — it's a nudge
        // on top of whatever white balance the image already has. Keeping it
        // here rather than at demosaic also means dragging it doesn't force a
        // re-decode of the raw file.
        if settings.incrementalTemperature != 0 || settings.incrementalTint != 0 {
            let incremental = ColorScience.whiteBalanceMatrix(
                kelvin: ColorScience.kelvinForRelative(settings.incrementalTemperature),
                tint: settings.incrementalTint
            )
            matrix = incremental * matrix
        }

        // Camera calibration sits before everything else in Adobe's pipeline
        // and is a linear operation, so it folds into the same matrix.
        if !settings.isCalibrationNeutral {
            let calibration = ColorScience.calibrationMatrix(
                redHue: settings.redHue,
                redSaturation: settings.redSaturation,
                greenHue: settings.greenHue,
                greenSaturation: settings.greenSaturation,
                blueHue: settings.blueHue,
                blueSaturation: settings.blueSaturation
            )
            matrix = calibration * matrix
        }

        let isIdentity = gain == 1.0 && matrix == matrix_identity_float3x3
        guard !isIdentity, let kernel = kernels.wbExposure else { return image }

        // simd matrices are column-major; the kernel wants rows.
        let row0 = CIVector(x: CGFloat(matrix[0][0]), y: CGFloat(matrix[1][0]), z: CGFloat(matrix[2][0]))
        let row1 = CIVector(x: CGFloat(matrix[0][1]), y: CGFloat(matrix[1][1]), z: CGFloat(matrix[2][1]))
        let row2 = CIVector(x: CGFloat(matrix[0][2]), y: CGFloat(matrix[1][2]), z: CGFloat(matrix[2][2]))

        return kernel.apply(
            extent: image.extent,
            arguments: [image, row0, row1, row2, gain]
        ) ?? image
    }

    private func applyBasicTone(_ image: CIImage, settings: EditSettings) -> CIImage {
        let isIdentity = settings.contrast == 0 && settings.highlights == 0
            && settings.shadows == 0 && settings.whites == 0 && settings.blacks == 0
            && settings.shadowTint == 0
        guard !isIdentity, let kernel = kernels.basicTone else { return image }

        return kernel.apply(extent: image.extent, arguments: [
            image,
            Float(settings.contrast / 100),
            Float(settings.highlights / 100),
            Float(settings.shadows / 100),
            Float(settings.whites / 100),
            Float(settings.blacks / 100),
            // Shadow Tint rides along here because it shares the shadow
            // weighting the tone sliders already compute.
            Float(settings.shadowTint / 100),
        ]) ?? image
    }

    private func applyToneCurves(_ image: CIImage, settings: EditSettings) -> CIImage {
        let baked = ToneCurveEvaluator.bake(settings)
        guard !baked.isIdentity else { return image }
        return applyCurves(image, data: Self.curvesData(from: baked)) ?? image
    }

    /// Adobe evaluates tone curves on gamma-encoded values, so the curve is
    /// applied in sRGB rather than the linear working space.
    private func applyCurves(_ image: CIImage, data: Data) -> CIImage? {
        image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": sRGB,
        ])
    }

    private static func curvesData(from baked: ToneCurveEvaluator.BakedCurves) -> Data {
        var interleaved = [Float](repeating: 0, count: baked.red.count * 3)
        for i in 0..<baked.red.count {
            interleaved[i * 3 + 0] = baked.red[i]
            interleaved[i * 3 + 1] = baked.green[i]
            interleaved[i * 3 + 2] = baked.blue[i]
        }
        return interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func applyColorMixer(_ image: CIImage, settings: EditSettings) -> CIImage {
        let isIdentity = !settings.convertToGrayscale
            && settings.hueAdjustments.isNeutral
            && settings.saturationAdjustments.isNeutral
            && settings.luminanceAdjustments.isNeutral
            && settings.vibrance == 0
            && settings.saturation == 0
        guard !isIdentity, let kernel = kernels.colorMixer else { return image }

        func pair(_ values: BandValues) -> [CIVector] {
            let f = values.values
            return [
                CIVector(values: [CGFloat(f[0]), CGFloat(f[1]), CGFloat(f[2]), CGFloat(f[3])], count: 4),
                CIVector(values: [CGFloat(f[4]), CGFloat(f[5]), CGFloat(f[6]), CGFloat(f[7])], count: 4),
            ]
        }

        let hue = pair(settings.hueAdjustments)
        let sat = pair(settings.saturationAdjustments)
        let lum = pair(settings.luminanceAdjustments)
        let gray = pair(settings.grayMixer)

        return kernel.apply(extent: image.extent, arguments: [
            image,
            hue[0], hue[1],
            sat[0], sat[1],
            lum[0], lum[1],
            gray[0], gray[1],
            Float(settings.vibrance),
            Float(settings.saturation),
            Float(settings.convertToGrayscale ? 1 : 0),
        ]) ?? image
    }

    private func applyColorGrading(_ image: CIImage, settings: EditSettings) -> CIImage {
        let g = settings.colorGrading
        guard !g.isNeutral, let kernel = kernels.colorGrade else { return image }

        func hsl(_ h: Double, _ s: Double, _ l: Double) -> CIVector {
            CIVector(x: CGFloat(h), y: CGFloat(s), z: CGFloat(l))
        }

        return kernel.apply(extent: image.extent, arguments: [
            image,
            hsl(g.shadowHue, g.shadowSat, g.shadowLum),
            hsl(g.midtoneHue, g.midtoneSat, g.midtoneLum),
            hsl(g.highlightHue, g.highlightSat, g.highlightLum),
            hsl(g.globalHue, g.globalSat, g.globalLum),
            Float(g.blending),
            Float(g.balance),
        ]) ?? image
    }

    private func applyDehaze(
        _ image: CIImage,
        settings: EditSettings,
        scale: CGFloat,
        extent: CGRect
    ) -> CIImage {
        guard settings.dehaze != 0,
              let kernel = kernels.dehaze,
              let darkKernel = kernels.darkChannel
        else { return image }

        guard let dark = darkKernel.apply(extent: extent, arguments: [image]) else { return image }

        // The airlight estimate wants a coarse, regional view of the scene.
        let radius = (28 * scale).clamped(to: 6...110)
        let blurredDark = dark
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: extent)

        return kernel.apply(
            extent: extent,
            arguments: [image, blurredDark, Float(settings.dehaze)]
        ) ?? image
    }

    private func applyClarityTexture(
        _ image: CIImage,
        settings: EditSettings,
        scale: CGFloat,
        extent: CGRect
    ) -> CIImage {
        guard settings.clarity != 0 || settings.texture != 0,
              let kernel = kernels.clarityTexture
        else { return image }

        let clamped = image.clampedToExtent()

        // Clarity works on a wide radius (midtone contrast), texture on a
        // tight one (fine detail). Both scale with resolution.
        let wideRadius = (22 * scale).clamped(to: 5...90)
        let fineRadius = (2.2 * scale).clamped(to: 1...9)

        let wide = clamped.applyingGaussianBlur(sigma: Double(wideRadius)).cropped(to: extent)
        let fine = clamped.applyingGaussianBlur(sigma: Double(fineRadius)).cropped(to: extent)

        return kernel.apply(extent: extent, arguments: [
            image, wide, fine,
            Float(settings.clarity),
            Float(settings.texture),
        ]) ?? image
    }

    private func applySharpening(
        _ image: CIImage,
        settings: EditSettings,
        scale: CGFloat,
        extent: CGRect
    ) -> CIImage {
        guard settings.sharpness > 0, let kernel = kernels.sharpen else { return image }

        let clamped = image.clampedToExtent()
        let radius = (settings.sharpenRadius * Double(scale)).clamped(to: 0.4...6)
        let blurred = clamped.applyingGaussianBlur(sigma: radius).cropped(to: extent)

        // Laplacian magnitude drives the edge mask.
        let edges = clamped.applyingFilter("CIConvolution3X3", parameters: [
            "inputWeights": CIVector(values: [0, -1, 0, -1, 4, -1, 0, -1, 0], count: 9),
            "inputBias": 0.0,
        ]).cropped(to: extent)

        return kernel.apply(extent: extent, arguments: [
            image, blurred, edges,
            Float(settings.sharpness),
            Float(settings.sharpenDetail),
            Float(settings.sharpenEdgeMasking),
        ]) ?? image
    }

    private func applyColorNoiseReduction(
        _ image: CIImage,
        settings: EditSettings,
        isRaw: Bool,
        scale: CGFloat,
        extent: CGRect
    ) -> CIImage {
        // Raw already had this applied at demosaic, where it's more effective.
        guard !isRaw, settings.colorNR > 0, let kernel = kernels.colorNoiseReduction else {
            return image
        }

        let radius = (settings.colorNR / 100 * 6 * Double(scale)).clamped(to: 0.5...12)
        let blurred = image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: extent)

        return kernel.apply(extent: extent, arguments: [
            image, blurred,
            Float(settings.colorNR),
            Float(settings.colorNRSmoothness),
        ]) ?? image
    }

    private func applyVignettes(
        _ image: CIImage,
        settings: EditSettings,
        extent: CGRect
    ) -> CIImage {
        var result = image

        // Lens vignette correction shares the post-crop kernel with a fixed,
        // fully feathered circular falloff.
        if settings.vignetteAmount != 0, let kernel = kernels.postCropVignette {
            result = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect },
                arguments: [
                    result,
                    CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height),
                    Float(settings.vignetteAmount),
                    Float(40), Float(80), Float(100),
                    Float(VignetteStyle.colorPriority.rawValue),
                    Float(0),
                ]
            ) ?? result
        }

        if settings.postCropVignetteAmount != 0, let kernel = kernels.postCropVignette {
            result = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect },
                arguments: [
                    result,
                    CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height),
                    Float(settings.postCropVignetteAmount),
                    Float(settings.postCropVignetteMidpoint),
                    Float(settings.postCropVignetteFeather),
                    Float(settings.postCropVignetteRoundness),
                    Float(settings.postCropVignetteStyle.rawValue),
                    Float(settings.postCropVignetteHighlightContrast),
                ]
            ) ?? result
        }

        return result
    }

    private func applyGrain(
        _ image: CIImage,
        settings: EditSettings,
        scale: CGFloat,
        extent: CGRect
    ) -> CIImage {
        guard settings.grainAmount > 0, let kernel = kernels.filmGrain else { return image }

        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [
                image,
                Float(settings.grainAmount),
                Float(settings.grainSize),
                Float(settings.grainFrequency),
                Float(max(scale, 0.05)),
            ]
        ) ?? image
    }

    // MARK: - Output

    /// Rasterises for on-screen display.
    func makeCGImage(_ image: CIImage, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let extent = image.extent
        guard extent.isRenderable else { return nil }
        return context.createCGImage(
            image,
            from: extent,
            format: .RGBA8,
            colorSpace: colorSpace ?? sRGB
        )
    }

    /// Encodes for export. Display P3 keeps the wider gamut a ProRAW file can
    /// actually hold; sRGB is the safe default for sharing.
    func encode(
        _ image: CIImage,
        as format: ExportFormat,
        quality: Double,
        colorSpace: CGColorSpace
    ) -> Data? {
        let extent = image.extent
        guard extent.isRenderable else { return nil }

        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]

        switch format {
        case .jpeg:
            return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
        case .heif:
            return context.heifRepresentation(
                of: image,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: options
            )
        case .png:
            return context.pngRepresentation(
                of: image,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [:]
            )
        case .tiff:
            return context.tiffRepresentation(
                of: image,
                format: .RGBA16,
                colorSpace: colorSpace,
                options: [:]
            )
        }
    }
}

extension CGRect {
    /// `CIImage.extent` is `CGRect.infinite` for generators and clamped
    /// images, which every render path here has to reject.
    var isRenderable: Bool {
        origin.x.isFinite && origin.y.isFinite
            && width.isFinite && height.isFinite
            && width > 0 && height > 0
            && width < 1e7 && height < 1e7
    }
}

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case heif = "HEIF"
    case png = "PNG"
    case tiff = "TIFF"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heif: "heic"
        case .png: "png"
        case .tiff: "tiff"
        }
    }

    var supportsQuality: Bool {
        self == .jpeg || self == .heif
    }
}
