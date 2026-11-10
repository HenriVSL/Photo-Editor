//
//  EditSettingsBlend.swift
//  Photo Editor
//
//  Parameter-space interpolation, which is how Lightroom's preset Amount
//  slider works: rather than cross-fading two rendered images, it dials each
//  parameter between where you were and where the preset puts you. Doing it
//  this way means a half-strength preset composes correctly with manual edits
//  made afterwards.
//

import Foundation

extension EditSettings {

    /// Interpolates every parameter towards `target`.
    /// - Parameter amount: 0 leaves `self` untouched, 1 returns `target`.
    func interpolated(towards target: EditSettings, amount: Double) -> EditSettings {
        let t = amount.clamped(to: 0...1)
        if t <= 0 { return self }
        if t >= 1 { return target }

        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }

        func lerpBands(_ a: BandValues, _ b: BandValues) -> BandValues {
            var out = BandValues()
            for band in ColorBand.allCases {
                out[band] = lerp(a[band], b[band])
            }
            return out
        }

        // Curves interpolate point-by-point when the shapes are compatible.
        // When they aren't, there's no meaningful midpoint, so the target
        // takes over at the halfway mark.
        func lerpCurve(_ a: PointCurve, _ b: PointCurve) -> PointCurve {
            if a.isLinear && b.isLinear { return .linear }
            if a.points.count == b.points.count {
                let points = zip(a.points, b.points).map { pa, pb in
                    CurvePoint(lerp(pa.x, pb.x), lerp(pa.y, pb.y))
                }
                return PointCurve(points: points)
            }
            if a.isLinear {
                // Growing out of a straight line: scale the target's deviation.
                let points = b.points.map { CurvePoint($0.x, lerp($0.x, $0.y)) }
                return PointCurve(points: points)
            }
            return t < 0.5 ? a : b
        }

        var out = EditSettings()

        out.whiteBalanceMode = t < 0.5 ? whiteBalanceMode : target.whiteBalanceMode
        out.isRawTemperature = t < 0.5 ? isRawTemperature : target.isRawTemperature
        // Only interpolate temperature when both sides use the same scale;
        // mixing Kelvin with a relative offset would produce nonsense.
        out.temperature = isRawTemperature == target.isRawTemperature
            ? lerp(temperature, target.temperature)
            : (t < 0.5 ? temperature : target.temperature)
        out.tint = lerp(tint, target.tint)
        out.incrementalTemperature = lerp(incrementalTemperature, target.incrementalTemperature)
        out.incrementalTint = lerp(incrementalTint, target.incrementalTint)

        out.shadowTint = lerp(shadowTint, target.shadowTint)
        out.redHue = lerp(redHue, target.redHue)
        out.redSaturation = lerp(redSaturation, target.redSaturation)
        out.greenHue = lerp(greenHue, target.greenHue)
        out.greenSaturation = lerp(greenSaturation, target.greenSaturation)
        out.blueHue = lerp(blueHue, target.blueHue)
        out.blueSaturation = lerp(blueSaturation, target.blueSaturation)

        out.exposure = lerp(exposure, target.exposure)
        out.contrast = lerp(contrast, target.contrast)
        out.highlights = lerp(highlights, target.highlights)
        out.shadows = lerp(shadows, target.shadows)
        out.whites = lerp(whites, target.whites)
        out.blacks = lerp(blacks, target.blacks)

        out.texture = lerp(texture, target.texture)
        out.clarity = lerp(clarity, target.clarity)
        out.dehaze = lerp(dehaze, target.dehaze)
        out.vibrance = lerp(vibrance, target.vibrance)
        out.saturation = lerp(saturation, target.saturation)

        out.parametricCurve = ParametricCurve(
            highlights: lerp(parametricCurve.highlights, target.parametricCurve.highlights),
            lights: lerp(parametricCurve.lights, target.parametricCurve.lights),
            darks: lerp(parametricCurve.darks, target.parametricCurve.darks),
            shadows: lerp(parametricCurve.shadows, target.parametricCurve.shadows),
            shadowSplit: lerp(parametricCurve.shadowSplit, target.parametricCurve.shadowSplit),
            midtoneSplit: lerp(parametricCurve.midtoneSplit, target.parametricCurve.midtoneSplit),
            highlightSplit: lerp(parametricCurve.highlightSplit, target.parametricCurve.highlightSplit)
        )
        out.curveRGB = lerpCurve(curveRGB, target.curveRGB)
        out.curveRed = lerpCurve(curveRed, target.curveRed)
        out.curveGreen = lerpCurve(curveGreen, target.curveGreen)
        out.curveBlue = lerpCurve(curveBlue, target.curveBlue)

        out.convertToGrayscale = t < 0.5 ? convertToGrayscale : target.convertToGrayscale
        out.hueAdjustments = lerpBands(hueAdjustments, target.hueAdjustments)
        out.saturationAdjustments = lerpBands(saturationAdjustments, target.saturationAdjustments)
        out.luminanceAdjustments = lerpBands(luminanceAdjustments, target.luminanceAdjustments)
        out.grayMixer = lerpBands(grayMixer, target.grayMixer)

        out.colorGrading = ColorGrading(
            shadowHue: lerpHue(colorGrading.shadowHue, target.colorGrading.shadowHue, t),
            shadowSat: lerp(colorGrading.shadowSat, target.colorGrading.shadowSat),
            shadowLum: lerp(colorGrading.shadowLum, target.colorGrading.shadowLum),
            midtoneHue: lerpHue(colorGrading.midtoneHue, target.colorGrading.midtoneHue, t),
            midtoneSat: lerp(colorGrading.midtoneSat, target.colorGrading.midtoneSat),
            midtoneLum: lerp(colorGrading.midtoneLum, target.colorGrading.midtoneLum),
            highlightHue: lerpHue(colorGrading.highlightHue, target.colorGrading.highlightHue, t),
            highlightSat: lerp(colorGrading.highlightSat, target.colorGrading.highlightSat),
            highlightLum: lerp(colorGrading.highlightLum, target.colorGrading.highlightLum),
            globalHue: lerpHue(colorGrading.globalHue, target.colorGrading.globalHue, t),
            globalSat: lerp(colorGrading.globalSat, target.colorGrading.globalSat),
            globalLum: lerp(colorGrading.globalLum, target.colorGrading.globalLum),
            blending: lerp(colorGrading.blending, target.colorGrading.blending),
            balance: lerp(colorGrading.balance, target.colorGrading.balance)
        )

        out.sharpness = lerp(sharpness, target.sharpness)
        out.sharpenRadius = lerp(sharpenRadius, target.sharpenRadius)
        out.sharpenDetail = lerp(sharpenDetail, target.sharpenDetail)
        out.sharpenEdgeMasking = lerp(sharpenEdgeMasking, target.sharpenEdgeMasking)
        out.luminanceNR = lerp(luminanceNR, target.luminanceNR)
        out.luminanceNRDetail = lerp(luminanceNRDetail, target.luminanceNRDetail)
        out.luminanceNRContrast = lerp(luminanceNRContrast, target.luminanceNRContrast)
        out.colorNR = lerp(colorNR, target.colorNR)
        out.colorNRDetail = lerp(colorNRDetail, target.colorNRDetail)
        out.colorNRSmoothness = lerp(colorNRSmoothness, target.colorNRSmoothness)

        out.postCropVignetteAmount = lerp(postCropVignetteAmount, target.postCropVignetteAmount)
        out.postCropVignetteMidpoint = lerp(postCropVignetteMidpoint, target.postCropVignetteMidpoint)
        out.postCropVignetteFeather = lerp(postCropVignetteFeather, target.postCropVignetteFeather)
        out.postCropVignetteRoundness = lerp(postCropVignetteRoundness, target.postCropVignetteRoundness)
        out.postCropVignetteStyle = t < 0.5 ? postCropVignetteStyle : target.postCropVignetteStyle
        out.postCropVignetteHighlightContrast = lerp(
            postCropVignetteHighlightContrast,
            target.postCropVignetteHighlightContrast
        )
        out.grainAmount = lerp(grainAmount, target.grainAmount)
        out.grainSize = lerp(grainSize, target.grainSize)
        out.grainFrequency = lerp(grainFrequency, target.grainFrequency)

        out.vignetteAmount = lerp(vignetteAmount, target.vignetteAmount)

        return out
    }

    /// Hues are angles, so interpolate the short way round the wheel.
    private func lerpHue(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = b - a
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let result = a + delta * t
        return (result.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}
