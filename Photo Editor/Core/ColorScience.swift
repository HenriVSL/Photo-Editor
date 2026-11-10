//
//  ColorScience.swift
//  Photo Editor
//
//  Chromatic adaptation for the white balance controls, plus the small matrix
//  helpers the renderer needs.
//
//  For raw files the temperature and tint go straight to `CIRAWFilter`, which
//  applies them camera-referred against the DNG's own colour matrices — that's
//  strictly more accurate than anything we can do downstream. The maths here
//  covers rendered files (JPEG/HEIC), where Adobe itself is working relative to
//  an already-baked white point.
//

import Foundation
import simd

enum ColorScience {

    // MARK: - Matrices

    /// Linear sRGB (D65) ↔ CIE XYZ.
    static let xyzFromSRGB = simd_double3x3(
        simd_double3(0.4124564, 0.2126729, 0.0193339),
        simd_double3(0.3575761, 0.7151522, 0.1191920),
        simd_double3(0.1804375, 0.0721750, 0.9503041)
    )

    static let srgbFromXYZ = xyzFromSRGB.inverse

    /// Bradford cone response, the adaptation Adobe uses.
    static let bradford = simd_double3x3(
        simd_double3(0.8951, -0.7502, 0.0389),
        simd_double3(0.2664, 1.7135, -0.0685),
        simd_double3(-0.1614, 0.0367, 1.0296)
    )

    static let bradfordInverse = bradford.inverse

    static let d65 = simd_double3(0.95047, 1.0, 1.08883)

    // MARK: - Correlated colour temperature

    /// Planckian locus chromaticity for a given CCT, using Kim et al.'s cubic
    /// approximation (valid 1667 K – 25000 K).
    static func planckianXY(kelvin: Double) -> simd_double2 {
        let t = kelvin.clamped(to: 1667...25000)
        let t2 = t * t
        let t3 = t2 * t

        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        }

        let x2 = x * x
        let x3 = x2 * x

        let y: Double
        switch t {
        case ..<2222:
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        case ..<4000:
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        default:
            y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }

        return simd_double2(x, y)
    }

    /// xy chromaticity → XYZ, normalised to Y = 1.
    static func xyzFrom(xy: simd_double2) -> simd_double3 {
        guard xy.y > 1e-6 else { return d65 }
        return simd_double3(xy.x / xy.y, 1.0, (1 - xy.x - xy.y) / xy.y)
    }

    /// CIE 1960 uv, used to offset along the green–magenta (tint) axis, which
    /// runs perpendicular to the Planckian locus.
    static func uvFrom(xy: simd_double2) -> simd_double2 {
        let d = -2 * xy.x + 12 * xy.y + 3
        guard abs(d) > 1e-9 else { return simd_double2(0, 0) }
        return simd_double2(4 * xy.x / d, 6 * xy.y / d)
    }

    static func xyFrom(uv: simd_double2) -> simd_double2 {
        let d = 2 * uv.x - 8 * uv.y + 4
        guard abs(d) > 1e-9 else { return simd_double2(0.3127, 0.3290) }
        return simd_double2(3 * uv.x / d, 2 * uv.y / d)
    }

    /// The white point implied by a temperature/tint pair.
    /// Positive tint is magenta, matching Adobe's slider direction.
    static func whitePoint(kelvin: Double, tint: Double) -> simd_double3 {
        let locus = planckianXY(kelvin: kelvin)
        var uv = uvFrom(xy: locus)

        // Slope of the locus at this temperature, so the tint offset is
        // genuinely perpendicular rather than a fixed vertical nudge.
        let delta = max(kelvin * 0.001, 1.0)
        let uvPlus = uvFrom(xy: planckianXY(kelvin: kelvin + delta))
        let uvMinus = uvFrom(xy: planckianXY(kelvin: kelvin - delta))
        var tangent = uvPlus - uvMinus
        let len = simd_length(tangent)
        tangent = len > 1e-9 ? tangent / len : simd_double2(1, 0)

        // The rendered image moves *opposite* to the white point: describing
        // the illuminant as greener makes the renderer compensate towards
        // magenta. This normal is oriented so that a positive tint ends up
        // magenta in the output, which is Adobe's direction.
        let normal = simd_double2(tangent.y, -tangent.x)

        // ±150 tint spans roughly ±0.05 in uv, which matches the visual range
        // of Adobe's slider.
        uv += normal * (tint / 150.0 * 0.05)

        return xyzFrom(xy: xyFrom(uv: uv))
    }

    // MARK: - Chromatic adaptation

    /// Bradford adaptation matrix taking `source` white to `destination` white,
    /// expressed in XYZ.
    static func adaptation(from source: simd_double3, to destination: simd_double3) -> simd_double3x3 {
        let srcCone = bradford * source
        let dstCone = bradford * destination
        let ratio = simd_double3(
            dstCone.x / max(srcCone.x, 1e-9),
            dstCone.y / max(srcCone.y, 1e-9),
            dstCone.z / max(srcCone.z, 1e-9)
        )
        let scale = simd_double3x3(diagonal: ratio)
        return bradfordInverse * scale * bradford
    }

    /// The white balance matrix to apply in linear sRGB working space.
    ///
    /// Raising the temperature tells the renderer the scene light was bluer, so
    /// it compensates by warming the image — the same direction as Lightroom.
    /// `baselineKelvin` is what "no change" means for this image: 5500 K for a
    /// rendered file, or the as-shot temperature for raw.
    static func whiteBalanceMatrix(
        kelvin: Double,
        tint: Double,
        baselineKelvin: Double = 5500,
        baselineTint: Double = 0
    ) -> simd_float3x3 {
        let source = whitePoint(kelvin: kelvin, tint: tint)
        let destination = whitePoint(kelvin: baselineKelvin, tint: baselineTint)
        let cat = adaptation(from: source, to: destination)
        let m = srgbFromXYZ * cat * xyzFromSRGB

        // Renormalise so a neutral input stays at the same luminance; the
        // adaptation alone can shift overall brightness by a few percent.
        let white = m * simd_double3(1, 1, 1)
        let luma = 0.2126 * white.x + 0.7152 * white.y + 0.0722 * white.z
        let normalized = luma > 1e-6 ? m * (1.0 / luma) : m

        return simd_float3x3(
            simd_float3(Float(normalized[0][0]), Float(normalized[0][1]), Float(normalized[0][2])),
            simd_float3(Float(normalized[1][0]), Float(normalized[1][1]), Float(normalized[1][2])),
            simd_float3(Float(normalized[2][0]), Float(normalized[2][1]), Float(normalized[2][2]))
        )
    }

    /// Maps Adobe's relative -100...100 temperature slider (used for rendered
    /// files) onto a Kelvin value around the 5500 K neutral.
    static func kelvinForRelative(_ relative: Double) -> Double {
        5500 * exp(relative / 100 * 0.55)
    }

    // MARK: - Camera calibration

    /// The Calibration panel expressed as a 3×3 transform.
    ///
    /// Each slider pair moves one of the three primaries: the hue slider
    /// rotates it around the colour wheel and the saturation slider pushes it
    /// towards or away from grey. Transforming the three basis vectors and
    /// reassembling them as columns gives a matrix that reproduces the effect
    /// — which is exactly what the panel is doing conceptually, redefining
    /// where "red", "green" and "blue" land before anything downstream sees
    /// the image.
    static func calibrationMatrix(
        redHue: Double, redSaturation: Double,
        greenHue: Double, greenSaturation: Double,
        blueHue: Double, blueSaturation: Double
    ) -> simd_float3x3 {
        // ±100 spans roughly ±25° of rotation.
        //
        // This scale matters more than it looks. The primaries are already
        // fully saturated, so the rotation angle is the entire strength of the
        // effect — at ±60° a preset with BlueHue = -65 drags the blue primary
        // all the way to cyan and floods the whole frame with it. ±25° keeps
        // even extreme presets in the range Camera Raw produces.
        func shifted(baseHue: Double, hue: Double, saturation: Double) -> simd_double3 {
            let rgb = rgbForHue(baseHue + hue / 100 * 25)
            var v = simd_double3(rgb.r, rgb.g, rgb.b)

            // Saturation pulls the primary towards or away from its own
            // luminance-matched grey.
            let scale = 1 + saturation / 100
            let grey = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
            v = simd_double3(repeating: grey) + (v - simd_double3(repeating: grey)) * scale
            return simd_max(v, simd_double3(repeating: 0))
        }

        let r = shifted(baseHue: 0, hue: redHue, saturation: redSaturation)
        let g = shifted(baseHue: 120, hue: greenHue, saturation: greenSaturation)
        let b = shifted(baseHue: 240, hue: blueHue, saturation: blueSaturation)

        // Columns are where each input primary ends up.
        var m = simd_double3x3(r, g, b)

        // Preserve the neutral axis, so white stays white and only the
        // primaries move.
        let white = m * simd_double3(1, 1, 1)
        let target = simd_double3(1, 1, 1)
        let correction = simd_double3x3(diagonal: simd_double3(
            target.x / max(white.x, 1e-6),
            target.y / max(white.y, 1e-6),
            target.z / max(white.z, 1e-6)
        ))
        m = correction * m

        return simd_float3x3(
            simd_float3(Float(m[0][0]), Float(m[0][1]), Float(m[0][2])),
            simd_float3(Float(m[1][0]), Float(m[1][1]), Float(m[1][2])),
            simd_float3(Float(m[2][0]), Float(m[2][1]), Float(m[2][2]))
        )
    }

    // MARK: - Helpers

    /// Fully saturated RGB for a hue in degrees — used for colour grading
    /// swatches and the hue slider gradients.
    static func rgbForHue(_ degrees: Double) -> (r: Double, g: Double, b: Double) {
        let h = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return (1, x, 0)
        case 1: return (x, 1, 0)
        case 2: return (0, 1, x)
        case 3: return (0, x, 1)
        case 4: return (x, 0, 1)
        default: return (1, 0, x)
        }
    }
}
