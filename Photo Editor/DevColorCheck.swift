//
//  DevColorCheck.swift
//  Photo Editor
//
//  DEVELOPMENT ONLY.
//
//  Runs a synthetic 24-patch ColorChecker through the pipeline and asserts the
//  colour invariants that should hold no matter what the sliders are set to.
//
//  A synthesised chart beats a photographed one here: the input values are
//  known exactly, so any deviation in the output is the pipeline's doing and
//  not the lighting, the lens or the sensor. Reference sRGB values are the
//  ColorChecker Classic manufacturer figures.
//
//  What this can and can't settle: it proves the pipeline is self-consistent —
//  neutrals stay neutral, identity is identity, controls move the right way.
//  It cannot prove the render matches Adobe, because that's a question about
//  Adobe's output, not about physical colour.
//

#if DEBUG

import CoreGraphics
import CoreImage
import Foundation

enum DevColorCheck {

    /// ColorChecker Classic, in reading order. Patches 19-24 are the neutral ramp.
    static let patches: [(name: String, hex: UInt32)] = [
        ("Dark skin", 0x735244), ("Light skin", 0xc29682), ("Blue sky", 0x627a9d),
        ("Foliage", 0x576c43), ("Blue flower", 0x8580b1), ("Bluish green", 0x67bdaa),
        ("Orange", 0xd67e2c), ("Purplish blue", 0x505ba6), ("Moderate red", 0xc15a63),
        ("Purple", 0x5e3c6c), ("Yellow green", 0x9dbc40), ("Orange yellow", 0xe0a32e),
        ("Blue", 0x383d96), ("Green", 0x469449), ("Red", 0xaf363c),
        ("Yellow", 0xe7c71f), ("Magenta", 0xbb5695), ("Cyan", 0x0885a1),
        ("White", 0xf3f3f3), ("Neutral 8", 0xc8c8c8), ("Neutral 6.5", 0xa0a0a0),
        ("Neutral 5", 0x7a7a7a), ("Neutral 3.5", 0x555555), ("Black", 0x343434),
    ]

    /// Indices of the six neutral patches.
    static let neutralIndices = 18...23

    private static let patchSize = 32
    private static let columns = 6
    private static let rows = 4

    // MARK: - Chart

    static func makeChart() -> CGImage? {
        let width = columns * patchSize
        let height = rows * patchSize
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for (index, patch) in patches.enumerated() {
            let column = index % columns
            let row = index / columns
            context.setFillColor(
                red: CGFloat((patch.hex >> 16) & 0xFF) / 255,
                green: CGFloat((patch.hex >> 8) & 0xFF) / 255,
                blue: CGFloat(patch.hex & 0xFF) / 255,
                alpha: 1
            )
            context.fill(CGRect(
                x: column * patchSize,
                // CGContext is bottom-up; keep reading order top-down.
                y: (rows - 1 - row) * patchSize,
                width: patchSize, height: patchSize
            ))
        }
        return context.makeImage()
    }

    /// Samples the centre of each patch, in 0...255 sRGB.
    static func readPatches(_ image: CGImage) -> [(r: Double, g: Double, b: Double)] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let cellWidth = width / columns
        let cellHeight = height / rows

        return patches.indices.map { index in
            let column = index % columns
            let row = index / columns
            let x = column * cellWidth + cellWidth / 2
            let y = row * cellHeight + cellHeight / 2      // top-down, matches draw order
            let offset = (y * width + x) * 4
            return (Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
        }
    }

    // MARK: - Checks

    static func run(emit: (String) -> Void) -> Int {
        guard let chart = makeChart() else {
            emit("ColorChecker: could not build the chart")
            return 1
        }

        let input = CIImage(cgImage: chart)
        let engine = RenderEngine.shared
        let reference = readPatches(chart)
        var problems = 0

        /// Returns nil rather than a short array when a render fails, so the
        /// checks below can bail instead of indexing off the end.
        func render(_ settings: EditSettings) -> [(r: Double, g: Double, b: Double)]? {
            let processed = engine.process(input, settings: settings, isRaw: false)
            guard let cg = engine.makeCGImage(processed) else { return nil }
            let result = readPatches(cg)
            return result.count == patches.count ? result : nil
        }

        func maxNeutralSplit(_ result: [(r: Double, g: Double, b: Double)]) -> Double {
            var worst = 0.0
            for i in neutralIndices where i < result.count {
                let p = result[i]
                worst = max(worst, max(abs(p.r - p.g), max(abs(p.g - p.b), abs(p.r - p.b))))
            }
            return worst
        }

        emit("ColorChecker invariants (synthetic 24-patch chart, values in 0-255)")

        /// Every check needs a successful render; a nil is itself a failure.
        func require(_ label: String, _ settings: EditSettings) -> [(r: Double, g: Double, b: Double)]? {
            guard let result = render(settings) else {
                emit("   FAIL \(label): render produced no patches")
                problems += 1
                return nil
            }
            return result
        }

        // 1. Identity. Neutral settings must round-trip the chart untouched.
        //    Any drift here is the whole pipeline leaking.
        if let identity = require("identity", EditSettings()) {
            var worst = 0.0
            var worstPatch = ""
            for (index, (out, ref)) in zip(identity, reference).enumerated() {
                let delta = max(abs(out.r - ref.r), max(abs(out.g - ref.g), abs(out.b - ref.b)))
                if delta > worst { worst = delta; worstPatch = patches[index].name }
            }
            let ok = worst <= 2
            if !ok { problems += 1 }
            emit(String(format: "   %@ identity round-trip: max deviation %.1f (%@)",
                        ok ? "ok  " : "FAIL", worst, worstPatch as NSString))
        }

        // 2. Neutrals must survive the Calibration panel. The matrix renormalises
        //    so white maps to white; if that ever breaks, greys pick up a cast
        //    and every calibration-using preset is wrong.
        var calibration = EditSettings()
        calibration.redHue = 100; calibration.redSaturation = 60
        calibration.greenHue = -100; calibration.greenSaturation = -40
        calibration.blueHue = 100; calibration.blueSaturation = 50
        if let result = require("calibration neutrals", calibration) {
            let split = maxNeutralSplit(result)
            if split > 3 { problems += 1 }
            emit(String(format: "   %@ neutrals under extreme calibration: split %.1f",
                        split <= 3 ? "ok  " : "FAIL", split))
        }

        // 3. Neutrals must survive the colour mixer, which weights by saturation
        //    precisely so achromatic pixels don't move.
        var mixer = EditSettings()
        for band in ColorBand.allCases {
            mixer.hueAdjustments[band] = 100
            mixer.saturationAdjustments[band] = -100
            mixer.luminanceAdjustments[band] = 100
        }
        if let result = require("mixer neutrals", mixer) {
            let split = maxNeutralSplit(result)
            if split > 3 { problems += 1 }
            emit(String(format: "   %@ neutrals under extreme colour mixer: split %.1f",
                        split <= 3 ? "ok  " : "FAIL", split))

            // Split alone isn't enough. A band's *luminance* adjustment moves
            // R, G and B together, so it shifts a neutral patch without
            // splitting it at all — which is how contour artifacts in a
            // near-white sky went undetected by the check above.
            var worstShift = 0.0
            for i in neutralIndices where i < result.count {
                worstShift = max(worstShift, abs(result[i].g - reference[i].g))
            }
            let holds = worstShift <= 3
            if !holds { problems += 1 }
            emit(String(format: "   %@ neutrals hold brightness under colour mixer: shift %.1f",
                        holds ? "ok  " : "FAIL", worstShift))
        }

        // 4. Tone controls must be monotonic — brighter in, brighter out.
        var brighter = EditSettings()
        brighter.exposure = 1.0
        if let lifted = require("exposure", brighter) {
            var monotonic = true
            for (out, ref) in zip(lifted, reference) where out.g + 1.5 < ref.g {
                monotonic = false
            }
            if !monotonic { problems += 1 }
            emit("   \(monotonic ? "ok  " : "FAIL") +1 EV brightens every patch")
        }

        // 5. Contrast must push the ramp apart, not shift it.
        var contrast = EditSettings()
        contrast.contrast = 60
        if let contrasted = require("contrast", contrast) {
            let darkBefore = reference[23].g, darkAfter = contrasted[23].g
            let lightBefore = reference[18].g, lightAfter = contrasted[18].g
            let spreads = darkAfter <= darkBefore + 1 && lightAfter >= lightBefore - 1
            if !spreads { problems += 1 }
            emit(String(format: "   %@ +60 contrast spreads the ramp (black %.0f→%.0f, white %.0f→%.0f)",
                        spreads ? "ok  " : "FAIL", darkBefore, darkAfter, lightBefore, lightAfter))
        }

        // 6. White balance must move in Adobe's direction: warmer means more
        //    red and less blue.
        var warm = EditSettings()
        warm.whiteBalanceMode = .custom
        warm.incrementalTemperature = 50
        let grey = 20   // Neutral 6.5
        if let warmed = require("white balance", warm) {
            let warmerRed = warmed[grey].r > reference[grey].r
            let warmerBlue = warmed[grey].b < reference[grey].b
            if !(warmerRed && warmerBlue) { problems += 1 }
            emit(String(format: "   %@ +50 temp warms grey (R %.0f→%.0f, B %.0f→%.0f)",
                        warmerRed && warmerBlue ? "ok  " : "FAIL",
                        reference[grey].r, warmed[grey].r, reference[grey].b, warmed[grey].b))
        }

        // 7. Tint positive is magenta: green down relative to red and blue.
        var magenta = EditSettings()
        magenta.whiteBalanceMode = .custom
        magenta.incrementalTint = 50
        if let tinted = require("tint", magenta) {
            let greenDrops = tinted[grey].g < reference[grey].g
            if !greenDrops { problems += 1 }
            emit(String(format: "   %@ +50 tint goes magenta (G %.0f→%.0f)",
                        greenDrops ? "ok  " : "FAIL", reference[grey].g, tinted[grey].g))
        }

        // 8. Split toning must tint without changing brightness, and must not
        //    blow a channel. A shadow hue near blue is the dangerous case:
        //    scaling a hue up to the pixel's luminance explodes when that hue's
        //    own luminance is small, which flooded whole images purple.
        var toning = EditSettings()
        toning.colorGrading.shadowHue = 263
        toning.colorGrading.shadowSat = 100
        toning.colorGrading.highlightHue = 56
        toning.colorGrading.highlightSat = 100
        toning.colorGrading.blending = 100
        if let toned = require("split toning", toning) {
            func meanLuma(_ p: [(r: Double, g: Double, b: Double)]) -> Double {
                p.reduce(0) { $0 + 0.2126 * $1.r + 0.7152 * $1.g + 0.0722 * $1.b } / Double(p.count)
            }
            let lumaShift = abs(meanLuma(toned) - meanLuma(reference))
            let lumaOK = lumaShift < 14
            if !lumaOK { problems += 1 }
            emit(String(format: "   %@ extreme split toning holds brightness: shift %.1f",
                        lumaOK ? "ok  " : "FAIL", lumaShift))

            func meanChannel(_ p: [(r: Double, g: Double, b: Double)], _ i: Int) -> Double {
                p.reduce(0) { $0 + (i == 0 ? $1.r : i == 1 ? $1.g : $1.b) } / Double(p.count)
            }
            var worstRatio = 1.0
            for channel in 0..<3 {
                let before = max(meanChannel(reference, channel), 1)
                worstRatio = max(worstRatio, meanChannel(toned, channel) / before)
            }
            let noBlowout = worstRatio < 1.6
            if !noBlowout { problems += 1 }
            emit(String(format: "   %@ extreme split toning doesn't blow a channel: %.2fx",
                        noBlowout ? "ok  " : "FAIL", worstRatio))
        }

        // 9. Black & white conversion must leave nothing coloured.
        var mono = EditSettings()
        mono.convertToGrayscale = true
        if let monochrome = require("black & white", mono) {
            var colourLeak = 0.0
            for p in monochrome {
                colourLeak = max(colourLeak, max(abs(p.r - p.g), max(abs(p.g - p.b), abs(p.r - p.b))))
            }
            if colourLeak > 3 { problems += 1 }
            emit(String(format: "   %@ B&W leaves no colour: max split %.1f",
                        colourLeak <= 3 ? "ok  " : "FAIL", colourLeak))
        }

        return problems
    }
}

#endif
