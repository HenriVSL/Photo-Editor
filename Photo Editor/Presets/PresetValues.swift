//
//  PresetValues.swift
//  Photo Editor
//
//  The intermediate representation every preset parser produces, plus the
//  mapping from Adobe's key vocabulary onto `EditSettings`.
//
//  Adobe has two generations of develop settings in the wild:
//
//  * Process 2012 and later (`Exposure2012`, `Highlights2012`, `Texture`,
//    `Dehaze`, `ToneCurvePV2012`, `ColorGrade*`) — what Lightroom Classic and
//    current Camera Raw write.
//  * Process 2003/2010 (`Exposure`, `Brightness`, `FillLight`,
//    `HighlightRecovery`, `ToneCurve`) — what .lrtemplate files and pre-2012
//    .xmp presets contain.
//
//  Both funnel through `RawPresetValues` so there's a single place where key
//  names turn into parameters.
//

import Foundation

/// Untyped key/value soup straight out of a preset file.
///
/// Kept alongside the parsed settings so that applying a preset can merge onto
/// the current edit rather than replacing it. That matters for partial presets
/// — a "Clarity only" preset shouldn't reset your exposure.
struct RawPresetValues: Hashable, Codable, Sendable {
    /// Scalar `crs:` values, keyed by their name with any namespace prefix removed.
    var scalars: [String: String] = [:]
    /// Ordered lists — tone curves (`"32, 22"` entries) and `rdf:Alt` text.
    var sequences: [String: [String]] = [:]

    subscript(key: String) -> String? { scalars[key] }

    func double(_ key: String) -> Double? {
        guard var s = scalars[key] else { return nil }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("+") { s.removeFirst() }
        return Double(s)
    }

    func bool(_ key: String) -> Bool? {
        guard let s = scalars[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if s == "true" || s == "1" { return true }
        if s == "false" || s == "0" { return false }
        return nil
    }

    func string(_ key: String) -> String? {
        sequences[key]?.first(where: { !$0.isEmpty })
            ?? scalars[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Parses an `rdf:Seq` of `"x, y"` entries into curve points.
    func curve(_ key: String) -> PointCurve? {
        guard let raw = sequences[key], !raw.isEmpty else { return nil }
        var points: [CurvePoint] = []
        for entry in raw {
            let parts = entry.split(separator: ",")
            guard parts.count >= 2,
                  let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            points.append(CurvePoint(x, y))
        }
        guard points.count >= 2 else { return nil }
        return PointCurve(points: points)
    }

    /// True when the file speaks the process-2012 vocabulary.
    var isProcess2012: Bool {
        if scalars.keys.contains(where: { $0.hasSuffix("2012") }) { return true }
        if sequences.keys.contains(where: { $0.hasPrefix("ToneCurvePV2012") }) { return true }
        if let pv = double("ProcessVersion"), pv >= 6.7 { return true }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Mapping

enum PresetMapper {

    /// Builds edit settings from parsed values, starting from `base` so that
    /// keys the preset doesn't mention keep their current value — which is how
    /// Lightroom presets behave (a partial preset only touches what it sets).
    static func settings(from raw: RawPresetValues, base: EditSettings = EditSettings()) -> EditSettings {
        var s = base
        if raw.isProcess2012 {
            applyModern(raw, to: &s)
        } else {
            applyLegacy(raw, to: &s)
        }
        applyShared(raw, to: &s)
        return s
    }

    // MARK: Process 2012+

    private static func applyModern(_ raw: RawPresetValues, to s: inout EditSettings) {
        if let v = raw.double("Exposure2012") { s.exposure = v }
        if let v = raw.double("Contrast2012") { s.contrast = v }
        if let v = raw.double("Highlights2012") { s.highlights = v }
        if let v = raw.double("Shadows2012") { s.shadows = v }
        if let v = raw.double("Whites2012") { s.whites = v }
        if let v = raw.double("Blacks2012") { s.blacks = v }
        if let v = raw.double("Clarity2012") { s.clarity = v }
        if let v = raw.double("Texture") { s.texture = v }
        if let v = raw.double("Dehaze") { s.dehaze = v }

        if let c = raw.curve("ToneCurvePV2012") { s.curveRGB = c }
        if let c = raw.curve("ToneCurvePV2012Red") { s.curveRed = c }
        if let c = raw.curve("ToneCurvePV2012Green") { s.curveGreen = c }
        if let c = raw.curve("ToneCurvePV2012Blue") { s.curveBlue = c }

        // Three-way colour grading supersedes split toning when present, but
        // Adobe still writes both. Prefer the ColorGrade* keys.
        if let v = raw.double("ColorGradeShadowHue") { s.colorGrading.shadowHue = v }
        if let v = raw.double("ColorGradeShadowSat") { s.colorGrading.shadowSat = v }
        if let v = raw.double("ColorGradeShadowLum") { s.colorGrading.shadowLum = v }
        if let v = raw.double("ColorGradeMidtoneHue") { s.colorGrading.midtoneHue = v }
        if let v = raw.double("ColorGradeMidtoneSat") { s.colorGrading.midtoneSat = v }
        if let v = raw.double("ColorGradeMidtoneLum") { s.colorGrading.midtoneLum = v }
        if let v = raw.double("ColorGradeHighlightHue") { s.colorGrading.highlightHue = v }
        if let v = raw.double("ColorGradeHighlightSat") { s.colorGrading.highlightSat = v }
        if let v = raw.double("ColorGradeHighlightLum") { s.colorGrading.highlightLum = v }
        if let v = raw.double("ColorGradeGlobalHue") { s.colorGrading.globalHue = v }
        if let v = raw.double("ColorGradeGlobalSat") { s.colorGrading.globalSat = v }
        if let v = raw.double("ColorGradeGlobalLum") { s.colorGrading.globalLum = v }
        if let v = raw.double("ColorGradeBlending") { s.colorGrading.blending = v }
    }

    // MARK: Process 2003/2010
    //
    // The legacy sliders don't have exact 2012 equivalents; Adobe's own
    // conversion is undocumented. These mappings preserve the *intent* of each
    // control and land close visually. Anything approximate is called out.

    private static func applyLegacy(_ raw: RawPresetValues, to s: inout EditSettings) {
        if let v = raw.double("Exposure") { s.exposure = v }

        // Legacy Contrast is 0-centred at 25, not 0.
        if let v = raw.double("Contrast") { s.contrast = ((v - 25) * 1.0).clamped(to: -100...100) }

        // Brightness (0...150, neutral 50) is a midtone lift. Split between a
        // small exposure nudge and a parametric midtone push so highlights
        // don't blow out the way a pure exposure change would.
        if let v = raw.double("Brightness") {
            let delta = (v - 50) / 50
            s.exposure += delta * 0.25
            s.parametricCurve.lights = (s.parametricCurve.lights + delta * 30).clamped(to: -100...100)
            s.parametricCurve.darks = (s.parametricCurve.darks + delta * 30).clamped(to: -100...100)
        }

        // Recovery pulls highlights down; Fill Light lifts shadows.
        if let v = raw.double("HighlightRecovery") { s.highlights = -v }
        if let v = raw.double("FillLight") { s.shadows = v }

        // In PV2003/2010 the slider labelled "Blacks" is stored as `Shadows`,
        // 0...100 with a neutral of 5. Higher means more black clipping.
        if let v = raw.double("Shadows") { s.blacks = (-(v - 5) * 2).clamped(to: -100...100) }

        if let v = raw.double("Clarity") { s.clarity = v }
        if let c = raw.curve("ToneCurve") { s.curveRGB = c }

        // Legacy split toning is the only grading available; map it onto the
        // shadow and highlight ends of the three-way grade.
        if let v = raw.double("SplitToningShadowHue") { s.colorGrading.shadowHue = v }
        if let v = raw.double("SplitToningShadowSaturation") { s.colorGrading.shadowSat = v }
        if let v = raw.double("SplitToningHighlightHue") { s.colorGrading.highlightHue = v }
        if let v = raw.double("SplitToningHighlightSaturation") { s.colorGrading.highlightSat = v }
    }

    // MARK: Shared between generations

    private static func applyShared(_ raw: RawPresetValues, to s: inout EditSettings) {
        if let v = raw.double("Vibrance") { s.vibrance = v }
        if let v = raw.double("Saturation") { s.saturation = v }

        // White balance. Raw presets carry an absolute Kelvin; the relative
        // -100...100 form used for rendered files never exceeds 100.
        if let mode = raw.string("WhiteBalance"), let parsed = WhiteBalanceMode(rawValue: mode) {
            s.whiteBalanceMode = parsed
        }
        if let v = raw.double("Temperature") {
            s.temperature = v
            s.isRawTemperature = abs(v) > 100
            if s.whiteBalanceMode == .asShot { s.whiteBalanceMode = .custom }
        }
        if let v = raw.double("Tint") { s.tint = v }

        // The relative form, which most presets use — they warm or cool
        // whatever white balance the photo already has instead of pinning a
        // Kelvin value. A preset carrying only these still means to change the
        // white balance, so treat it as a custom setting.
        if let v = raw.double("IncrementalTemperature") {
            s.incrementalTemperature = v
            if v != 0, s.whiteBalanceMode == .asShot { s.whiteBalanceMode = .custom }
        }
        if let v = raw.double("IncrementalTint") {
            s.incrementalTint = v
            if v != 0, s.whiteBalanceMode == .asShot { s.whiteBalanceMode = .custom }
        }

        // Adobe's profile name. "Embedded" means the DNG's own profile, which
        // for an Apple ProRAW file is Apple's — the most common value in
        // circulating presets by a wide margin.
        if let profile = raw.string("CameraProfile") {
            s.rawRendering = profile.caseInsensitiveCompare("Embedded") == .orderedSame
                ? .cameraMatch
                : s.rawRendering
        }

        // Camera calibration.
        if let v = raw.double("ShadowTint") { s.shadowTint = v }
        if let v = raw.double("RedHue") { s.redHue = v }
        if let v = raw.double("RedSaturation") { s.redSaturation = v }
        if let v = raw.double("GreenHue") { s.greenHue = v }
        if let v = raw.double("GreenSaturation") { s.greenSaturation = v }
        if let v = raw.double("BlueHue") { s.blueHue = v }
        if let v = raw.double("BlueSaturation") { s.blueSaturation = v }

        // Parametric curve.
        if let v = raw.double("ParametricShadows") { s.parametricCurve.shadows = v }
        if let v = raw.double("ParametricDarks") { s.parametricCurve.darks = v }
        if let v = raw.double("ParametricLights") { s.parametricCurve.lights = v }
        if let v = raw.double("ParametricHighlights") { s.parametricCurve.highlights = v }
        if let v = raw.double("ParametricShadowSplit") { s.parametricCurve.shadowSplit = v }
        if let v = raw.double("ParametricMidtoneSplit") { s.parametricCurve.midtoneSplit = v }
        if let v = raw.double("ParametricHighlightSplit") { s.parametricCurve.highlightSplit = v }

        // Colour mixer / B&W mixer.
        if let v = raw.bool("ConvertToGrayscale") { s.convertToGrayscale = v }
        for band in ColorBand.allCases {
            if let v = raw.double("HueAdjustment\(band.xmpSuffix)") { s.hueAdjustments[band] = v }
            if let v = raw.double("SaturationAdjustment\(band.xmpSuffix)") { s.saturationAdjustments[band] = v }
            if let v = raw.double("LuminanceAdjustment\(band.xmpSuffix)") { s.luminanceAdjustments[band] = v }
            if let v = raw.double("GrayMixer\(band.xmpSuffix)") { s.grayMixer[band] = v }
        }

        // Split toning also exists in PV2012 files; only take it if the
        // three-way grade left the corresponding slot untouched.
        if s.colorGrading.shadowSat == 0, let v = raw.double("SplitToningShadowSaturation"), v != 0 {
            s.colorGrading.shadowSat = v
            s.colorGrading.shadowHue = raw.double("SplitToningShadowHue") ?? 0
        }
        if s.colorGrading.highlightSat == 0, let v = raw.double("SplitToningHighlightSaturation"), v != 0 {
            s.colorGrading.highlightSat = v
            s.colorGrading.highlightHue = raw.double("SplitToningHighlightHue") ?? 0
        }
        if let v = raw.double("SplitToningBalance") { s.colorGrading.balance = v }

        // Detail.
        if let v = raw.double("Sharpness") { s.sharpness = v }
        if let v = raw.double("SharpenRadius") { s.sharpenRadius = v }
        if let v = raw.double("SharpenDetail") { s.sharpenDetail = v }
        if let v = raw.double("SharpenEdgeMasking") { s.sharpenEdgeMasking = v }
        if let v = raw.double("LuminanceSmoothing") { s.luminanceNR = v }
        if let v = raw.double("LuminanceNoiseReductionDetail") { s.luminanceNRDetail = v }
        if let v = raw.double("LuminanceNoiseReductionContrast") { s.luminanceNRContrast = v }
        if let v = raw.double("ColorNoiseReduction") { s.colorNR = v }
        if let v = raw.double("ColorNoiseReductionDetail") { s.colorNRDetail = v }
        if let v = raw.double("ColorNoiseReductionSmoothness") { s.colorNRSmoothness = v }

        // Effects.
        if let v = raw.double("PostCropVignetteAmount") { s.postCropVignetteAmount = v }
        if let v = raw.double("PostCropVignetteMidpoint") { s.postCropVignetteMidpoint = v }
        if let v = raw.double("PostCropVignetteFeather") { s.postCropVignetteFeather = v }
        if let v = raw.double("PostCropVignetteRoundness") { s.postCropVignetteRoundness = v }
        if let v = raw.double("PostCropVignetteHighlightContrast") { s.postCropVignetteHighlightContrast = v }
        if let v = raw.double("PostCropVignetteStyle"), let style = VignetteStyle(rawValue: Int(v)) {
            s.postCropVignetteStyle = style
        }
        if let v = raw.double("GrainAmount") { s.grainAmount = v }
        if let v = raw.double("GrainSize") { s.grainSize = v }
        if let v = raw.double("GrainFrequency") { s.grainFrequency = v }

        if let v = raw.double("VignetteAmount") { s.vignetteAmount = v }
    }
}
