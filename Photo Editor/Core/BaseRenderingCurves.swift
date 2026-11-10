//
//  BaseRenderingCurves.swift
//  Photo Editor
//
//  The tone curves that turn a decoded raw file into a sensible starting
//  point, before any slider is touched.
//
//  Which one applies depends on the file:
//
//  * Apple ProRAW — none. The DNG embeds Apple's own profile and CIRAWFilter
//    applies it, which measured within 1.7/255 of a Lightroom export. Adding
//    anything on top would double up.
//  * Any other raw — `adobeMatch`. CIRAWFilter's generic rendering for a
//    third-party DNG is much flatter than Adobe Color, leaving images
//    conspicuously dark.
//  * The `.neutral` profile — `neutral`, a mild S-curve over linear data.
//

import CoreImage
import Foundation

enum BaseRenderingCurves {

    /// Mild S-curve for the `.neutral` rendering, which starts from linear
    /// sensor data. Not an attempt to match anyone — just enough to make a
    /// linear decode usable while keeping full highlight latitude.
    private static let neutralPoints = PointCurve(points: [
        CurvePoint(0, 0),
        CurvePoint(26, 18),
        CurvePoint(64, 56),
        CurvePoint(128, 132),
        CurvePoint(191, 201),
        CurvePoint(230, 231),
        CurvePoint(255, 255),
    ])

    /// Brings a non-Apple raw up to what Lightroom Classic produces.
    ///
    /// Measured, not guessed: fitted from the per-channel transfer function
    /// between our render and a Lightroom Classic 16-bit export of the same
    /// OPPO Find X7 Ultra DNG, 4096x3072, compared pixel for pixel. The
    /// deviation was a clean monotonic shadow lift of +30 to +38 levels through
    /// the midrange, consistent across R, G and B.
    ///
    /// Caveat worth keeping in mind: this was fitted from **one camera**.
    /// Adobe ships a different colour profile per body, so another camera will
    /// land close but not exact. It is far better than the ~20/255 error of
    /// applying nothing, which is what this replaces.
    private static let adobeMatchPoints = PointCurve(points: [
        CurvePoint(0, 0),
        CurvePoint(26, 56),
        CurvePoint(64, 102),
        CurvePoint(128, 161),
        CurvePoint(191, 214),
        CurvePoint(230, 240),
        CurvePoint(255, 255),
    ])

    static let neutral: Data = curveData(neutralPoints)
    static let adobeMatch: Data = curveData(adobeMatchPoints)

    private static func curveData(_ curve: PointCurve) -> Data {
        var settings = EditSettings()
        settings.curveRGB = curve
        let baked = ToneCurveEvaluator.bake(settings)

        var interleaved = [Float](repeating: 0, count: baked.red.count * 3)
        for i in 0..<baked.red.count {
            interleaved[i * 3 + 0] = baked.red[i]
            interleaved[i * 3 + 1] = baked.green[i]
            interleaved[i * 3 + 2] = baked.blue[i]
        }
        return interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Applies a baked curve. Evaluated in sRGB rather than the linear working
    /// space, because that's where the transfer function was measured — and
    /// where Adobe evaluates tone curves.
    static func apply(_ data: Data, to image: CIImage) -> CIImage {
        image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": sRGB,
        ])
    }
}
