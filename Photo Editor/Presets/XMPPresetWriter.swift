//
//  XMPPresetWriter.swift
//  Photo Editor
//
//  Writes an `EditSettings` back out as a process-2012 Camera Raw preset.
//  The structure, key order and number formatting follow what current Camera
//  Raw emits, so the result imports into Lightroom Classic and Camera Raw
//  without complaint.
//

import Foundation

enum XMPPresetWriter {

    static func xmp(for preset: Preset) -> String {
        let s = preset.settings
        let uuid = (preset.sourceUUID ?? preset.id.uuidString)
            .replacingOccurrences(of: "-", with: "")
            .uppercased()

        var attributes: [(String, String)] = [
            ("PresetType", "Normal"),
            ("Cluster", ""),
            ("UUID", uuid),
            ("SupportsAmount2", "True"),
            ("SupportsAmount", "True"),
            ("SupportsColor", "True"),
            ("SupportsMonochrome", "True"),
            ("SupportsHighDynamicRange", "True"),
            ("SupportsNormalDynamicRange", "True"),
            ("SupportsSceneReferred", "True"),
            ("SupportsOutputReferred", "True"),
            ("RequiresRGBTables", "False"),
            ("CameraModelRestriction", ""),
            ("Copyright", ""),
            ("ContactInfo", ""),
            ("Version", "14.5"),
            ("ProcessVersion", "11.0"),
        ]

        // White balance.
        if s.whiteBalanceMode != .asShot {
            attributes.append(("WhiteBalance", s.whiteBalanceMode.rawValue))
        }
        if s.temperature != 0 {
            attributes.append(("Temperature", s.isRawTemperature
                ? String(Int(s.temperature.rounded()))
                : signed(s.temperature)))
        }
        if s.tint != 0 { attributes.append(("Tint", signed(s.tint))) }
        if s.incrementalTemperature != 0 {
            attributes.append(("IncrementalTemperature", signed(s.incrementalTemperature)))
        }
        if s.incrementalTint != 0 {
            attributes.append(("IncrementalTint", signed(s.incrementalTint)))
        }

        // Light.
        attributes.append(("Exposure2012", signed(s.exposure, decimals: 2)))
        attributes.append(("Contrast2012", signed(s.contrast)))
        attributes.append(("Highlights2012", signed(s.highlights)))
        attributes.append(("Shadows2012", signed(s.shadows)))
        attributes.append(("Whites2012", signed(s.whites)))
        attributes.append(("Blacks2012", signed(s.blacks)))

        // Presence.
        attributes.append(("Texture", signed(s.texture)))
        attributes.append(("Clarity2012", signed(s.clarity)))
        attributes.append(("Dehaze", signed(s.dehaze)))
        attributes.append(("Vibrance", signed(s.vibrance)))
        attributes.append(("Saturation", signed(s.saturation)))

        // Parametric curve.
        attributes.append(("ParametricShadows", signed(s.parametricCurve.shadows)))
        attributes.append(("ParametricDarks", signed(s.parametricCurve.darks)))
        attributes.append(("ParametricLights", signed(s.parametricCurve.lights)))
        attributes.append(("ParametricHighlights", signed(s.parametricCurve.highlights)))
        attributes.append(("ParametricShadowSplit", unsigned(s.parametricCurve.shadowSplit)))
        attributes.append(("ParametricMidtoneSplit", unsigned(s.parametricCurve.midtoneSplit)))
        attributes.append(("ParametricHighlightSplit", unsigned(s.parametricCurve.highlightSplit)))

        // Detail.
        attributes.append(("Sharpness", unsigned(s.sharpness)))
        attributes.append(("SharpenRadius", String(format: "%+.1f", s.sharpenRadius)))
        attributes.append(("SharpenDetail", unsigned(s.sharpenDetail)))
        attributes.append(("SharpenEdgeMasking", unsigned(s.sharpenEdgeMasking)))
        attributes.append(("LuminanceSmoothing", unsigned(s.luminanceNR)))
        attributes.append(("LuminanceNoiseReductionDetail", unsigned(s.luminanceNRDetail)))
        attributes.append(("LuminanceNoiseReductionContrast", unsigned(s.luminanceNRContrast)))
        attributes.append(("ColorNoiseReduction", unsigned(s.colorNR)))
        attributes.append(("ColorNoiseReductionDetail", unsigned(s.colorNRDetail)))
        attributes.append(("ColorNoiseReductionSmoothness", unsigned(s.colorNRSmoothness)))

        // Colour mixer.
        for band in ColorBand.allCases {
            attributes.append(("HueAdjustment\(band.xmpSuffix)", signed(s.hueAdjustments[band])))
        }
        for band in ColorBand.allCases {
            attributes.append(("SaturationAdjustment\(band.xmpSuffix)", signed(s.saturationAdjustments[band])))
        }
        for band in ColorBand.allCases {
            attributes.append(("LuminanceAdjustment\(band.xmpSuffix)", signed(s.luminanceAdjustments[band])))
        }
        if s.convertToGrayscale {
            for band in ColorBand.allCases {
                attributes.append(("GrayMixer\(band.xmpSuffix)", signed(s.grayMixer[band])))
            }
        }

        // Split toning is still written for compatibility with older readers;
        // it mirrors the shadow and highlight ends of the three-way grade.
        attributes.append(("SplitToningShadowHue", unsigned(s.colorGrading.shadowHue)))
        attributes.append(("SplitToningShadowSaturation", unsigned(s.colorGrading.shadowSat)))
        attributes.append(("SplitToningHighlightHue", unsigned(s.colorGrading.highlightHue)))
        attributes.append(("SplitToningHighlightSaturation", unsigned(s.colorGrading.highlightSat)))
        attributes.append(("SplitToningBalance", signed(s.colorGrading.balance)))

        // Three-way colour grading.
        let g = s.colorGrading
        attributes.append(("ColorGradeMidtoneHue", unsigned(g.midtoneHue)))
        attributes.append(("ColorGradeMidtoneSat", unsigned(g.midtoneSat)))
        attributes.append(("ColorGradeShadowLum", signed(g.shadowLum)))
        attributes.append(("ColorGradeMidtoneLum", signed(g.midtoneLum)))
        attributes.append(("ColorGradeHighlightLum", signed(g.highlightLum)))
        attributes.append(("ColorGradeBlending", unsigned(g.blending)))
        attributes.append(("ColorGradeGlobalHue", unsigned(g.globalHue)))
        attributes.append(("ColorGradeGlobalSat", unsigned(g.globalSat)))
        attributes.append(("ColorGradeGlobalLum", signed(g.globalLum)))

        // Effects.
        attributes.append(("VignetteAmount", signed(s.vignetteAmount)))
        attributes.append(("GrainAmount", unsigned(s.grainAmount)))
        if s.grainAmount != 0 {
            attributes.append(("GrainSize", unsigned(s.grainSize)))
            attributes.append(("GrainFrequency", unsigned(s.grainFrequency)))
        }
        attributes.append(("PostCropVignetteAmount", signed(s.postCropVignetteAmount)))
        if s.postCropVignetteAmount != 0 {
            attributes.append(("PostCropVignetteMidpoint", unsigned(s.postCropVignetteMidpoint)))
            attributes.append(("PostCropVignetteFeather", unsigned(s.postCropVignetteFeather)))
            attributes.append(("PostCropVignetteRoundness", signed(s.postCropVignetteRoundness)))
            attributes.append(("PostCropVignetteStyle", String(s.postCropVignetteStyle.rawValue)))
            attributes.append(("PostCropVignetteHighlightContrast", unsigned(s.postCropVignetteHighlightContrast)))
        }

        // Camera calibration.
        attributes.append(("ShadowTint", signed(s.shadowTint)))
        attributes.append(("RedHue", signed(s.redHue)))
        attributes.append(("RedSaturation", signed(s.redSaturation)))
        attributes.append(("GreenHue", signed(s.greenHue)))
        attributes.append(("GreenSaturation", signed(s.greenSaturation)))
        attributes.append(("BlueHue", signed(s.blueHue)))
        attributes.append(("BlueSaturation", signed(s.blueSaturation)))

        attributes.append(("ConvertToGrayscale", s.convertToGrayscale ? "True" : "False"))
        attributes.append(("ToneCurveName2012", s.curveRGB.isLinear ? "Linear" : "Custom"))
        attributes.append(("CameraProfile", "Adobe Standard"))
        attributes.append(("HasSettings", "True"))

        // MARK: Assemble

        var xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Photo Editor 1.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="\(XMPPresetParser.cameraRawNamespace)"
        """

        for (key, value) in attributes {
            xml += "\n   crs:\(key)=\"\(escape(value))\""
        }
        xml += ">\n"

        xml += altBlock("Name", preset.name)
        xml += altBlock("ShortName", "")
        xml += altBlock("SortName", "")
        xml += altBlock("Group", preset.effectiveGroup)
        xml += altBlock("Description", preset.notes ?? "")

        xml += curveBlock("ToneCurvePV2012", s.curveRGB)
        xml += curveBlock("ToneCurvePV2012Red", s.curveRed)
        xml += curveBlock("ToneCurvePV2012Green", s.curveGreen)
        xml += curveBlock("ToneCurvePV2012Blue", s.curveBlue)

        xml += """
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """

        return xml
    }

    static func data(for preset: Preset) -> Data {
        Data(xmp(for: preset).utf8)
    }

    // MARK: - Formatting

    /// Bipolar sliders are written with an explicit sign, as Adobe does.
    private static func signed(_ value: Double, decimals: Int = 0) -> String {
        if decimals == 0 {
            let i = Int(value.rounded())
            return i >= 0 ? "+\(i)" : "\(i)"
        }
        return String(format: "%+.\(decimals)f", value)
    }

    private static func unsigned(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func altBlock(_ key: String, _ value: String) -> String {
        let inner = value.isEmpty
            ? "     <rdf:li xml:lang=\"x-default\"/>\n"
            : "     <rdf:li xml:lang=\"x-default\">\(escape(value))</rdf:li>\n"
        return """
           <crs:\(key)>
            <rdf:Alt>
        \(inner)    </rdf:Alt>
           </crs:\(key)>

        """
    }

    private static func curveBlock(_ key: String, _ curve: PointCurve) -> String {
        var xml = "   <crs:\(key)>\n    <rdf:Seq>\n"
        for point in curve.points {
            xml += "     <rdf:li>\(Int(point.x.rounded())), \(Int(point.y.rounded()))</rdf:li>\n"
        }
        xml += "    </rdf:Seq>\n   </crs:\(key)>\n"
        return xml
    }
}
