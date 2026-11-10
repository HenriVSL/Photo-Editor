//
//  AdjustmentPanels.swift
//  Photo Editor
//
//  The adjustment panels. Each one mirrors a Camera Raw panel and edits the
//  same parameters a preset carries, so anything you can dial in here can be
//  saved back out as an .xmp.
//

import SwiftUI

// MARK: - Tabs

enum PanelTab: String, CaseIterable, Identifiable {
    case light = "Light"
    case color = "Color"
    case mixer = "Mixer"
    case curve = "Curve"
    case grading = "Grading"
    case effects = "Effects"
    case detail = "Detail"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .light: "sun.max"
        case .color: "drop"
        case .mixer: "paintpalette"
        case .curve: "point.topleft.down.to.point.bottomright.curvepath"
        case .grading: "circle.hexagongrid"
        case .effects: "sparkles"
        case .detail: "wand.and.rays"
        }
    }
}

struct PanelTabBar: View {
    @Binding var selection: PanelTab

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(PanelTab.allCases) { tab in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                selection = tab
                                proxy.scrollTo(tab.id, anchor: .center)
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: tab.systemImage)
                                    .font(.system(size: 15))
                                Text(tab.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(width: 62, height: 46)
                            .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                            .background {
                                if selection == tab {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.accentColor.opacity(0.14))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }
}

// MARK: - Container

struct AdjustmentPanelView: View {
    let model: EditorModel
    @Binding var tab: PanelTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                switch tab {
                case .light: LightPanel(model: model)
                case .color: ColorPanel(model: model)
                case .mixer: MixerPanel(model: model)
                case .curve: CurvePanel(model: model)
                case .grading: GradingPanel(model: model)
                case .effects: EffectsPanel(model: model)
                case .detail: DetailPanel(model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Light

struct LightPanel: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 2) {
            slider(EditSettings.Spec.exposure, \.exposure)
            slider(EditSettings.Spec.contrast, \.contrast)
            slider(EditSettings.Spec.highlights, \.highlights)
            slider(EditSettings.Spec.shadows, \.shadows)
            slider(EditSettings.Spec.whites, \.whites)
            slider(EditSettings.Spec.blacks, \.blacks)
        }
    }

    private func slider(
        _ spec: ParameterSpec,
        _ keyPath: WritableKeyPath<EditSettings, Double>
    ) -> some View {
        AdjustmentSlider(
            spec: spec,
            value: model.binding(keyPath),
            onEditingBegan: model.beginInteraction
        )
    }
}

// MARK: - Color

struct ColorPanel: View {
    let model: EditorModel

    private var isRaw: Bool { model.settings.isRawTemperature }

    private var temperatureGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.30, green: 0.55, blue: 1.0),
                     Color(white: 0.85),
                     Color(red: 1.0, green: 0.78, blue: 0.30)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var tintGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.35, green: 0.85, blue: 0.35),
                     Color(white: 0.85),
                     Color(red: 0.90, green: 0.35, blue: 0.85)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Raw only — a JPEG or HEIC already carries a baked-in rendering.
            if isRaw {
                AdjustmentSection("Profile") {
                    Picker("Profile", selection: Binding(
                        get: { model.settings.rawRendering },
                        set: { model.update(\.rawRendering, to: $0) }
                    )) {
                        ForEach(RawRendering.allCases, id: \.self) { rendering in
                            Text(rendering.rawValue).tag(rendering)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(model.settings.rawRendering.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider().opacity(0.3)
            }

            AdjustmentSection("White Balance") {
                Picker("White Balance", selection: Binding(
                    get: { model.settings.whiteBalanceMode },
                    set: { model.update(\.whiteBalanceMode, to: $0) }
                )) {
                    ForEach(whiteBalanceOptions, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if isRaw {
                    // Raw carries a real Kelvin white point, applied against
                    // the DNG's colour matrices at demosaic time.
                    AdjustmentSlider(
                        spec: EditSettings.Spec.tempKelvin,
                        value: model.whiteBalanceBinding(\.temperature),
                        onEditingBegan: model.beginInteraction,
                        trackGradient: temperatureGradient
                    )
                    AdjustmentSlider(
                        spec: EditSettings.Spec.tintRaw,
                        value: model.whiteBalanceBinding(\.tint),
                        onEditingBegan: model.beginInteraction,
                        trackGradient: tintGradient
                    )
                } else {
                    // A rendered file has no camera white point to set, so
                    // Adobe exposes the relative shift instead — and so do we.
                    AdjustmentSlider(
                        spec: EditSettings.Spec.tempRelative,
                        value: model.binding(\.incrementalTemperature),
                        onEditingBegan: model.beginInteraction,
                        trackGradient: temperatureGradient
                    )
                    AdjustmentSlider(
                        spec: EditSettings.Spec.tintRelative,
                        value: model.binding(\.incrementalTint),
                        onEditingBegan: model.beginInteraction,
                        trackGradient: tintGradient
                    )
                }
            }

            // A preset can carry a relative shift on top of a raw file's own
            // Kelvin setting. Surface it when it's doing something, so the
            // effect is visible and adjustable rather than invisible.
            if isRaw, model.settings.incrementalTemperature != 0 || model.settings.incrementalTint != 0 {
                AdjustmentSection("Preset White Balance Shift") {
                    AdjustmentSlider(
                        spec: ParameterSpec("Warmth", -100...100),
                        value: model.binding(\.incrementalTemperature),
                        onEditingBegan: model.beginInteraction,
                        trackGradient: temperatureGradient
                    )
                    AdjustmentSlider(
                        spec: ParameterSpec("Tint Shift", -100...100),
                        value: model.binding(\.incrementalTint),
                        onEditingBegan: model.beginInteraction,
                        trackGradient: tintGradient
                    )
                }
            }

            Divider().opacity(0.3)

            AdjustmentSection("Presence") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.vibrance,
                    value: model.binding(\.vibrance),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.saturation,
                    value: model.binding(\.saturation),
                    onEditingBegan: model.beginInteraction
                )
            }

            Divider().opacity(0.3)

            AdjustmentSection("Calibration") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.shadowTint,
                    value: model.binding(\.shadowTint),
                    onEditingBegan: model.beginInteraction,
                    trackGradient: tintGradient
                )
                primaryRow("Red Primary", \.redHue, \.redSaturation)
                primaryRow("Green Primary", \.greenHue, \.greenSaturation)
                primaryRow("Blue Primary", \.blueHue, \.blueSaturation)
            }
        }
    }

    @ViewBuilder
    private func primaryRow(
        _ title: String,
        _ hue: WritableKeyPath<EditSettings, Double>,
        _ saturation: WritableKeyPath<EditSettings, Double>
    ) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        AdjustmentSlider(
            spec: EditSettings.Spec.primaryHue,
            value: model.binding(hue),
            onEditingBegan: model.beginInteraction
        )
        AdjustmentSlider(
            spec: EditSettings.Spec.primarySaturation,
            value: model.binding(saturation),
            onEditingBegan: model.beginInteraction
        )
    }

    private var whiteBalanceOptions: [WhiteBalanceMode] {
        isRaw
            ? [.asShot, .custom, .daylight, .cloudy, .shade, .tungsten, .fluorescent, .flash]
            : [.asShot, .custom]
    }
}

// MARK: - Colour mixer / B&W

struct MixerPanel: View {
    let model: EditorModel
    @State private var band: ColorBand = .red

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Black & White", isOn: model.binding(\.convertToGrayscale))
                .font(.system(size: 14))
                .tint(.accentColor)

            bandPicker

            if model.settings.convertToGrayscale {
                AdjustmentSlider(
                    spec: ParameterSpec("\(band.displayName) Mix", -100...100),
                    value: model.bandBinding(\.grayMixer, band),
                    onEditingBegan: model.beginInteraction
                )
                Text("Brightens or darkens areas that were this colour before the conversion. Neutral greys are unaffected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                AdjustmentSlider(
                    spec: EditSettings.Spec.bandHue,
                    value: model.bandBinding(\.hueAdjustments, band),
                    onEditingBegan: model.beginInteraction,
                    trackGradient: hueGradient
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.bandSaturation,
                    value: model.bandBinding(\.saturationAdjustments, band),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.bandLuminance,
                    value: model.bandBinding(\.luminanceAdjustments, band),
                    onEditingBegan: model.beginInteraction
                )
            }
        }
    }

    private var bandPicker: some View {
        HStack(spacing: 6) {
            ForEach(ColorBand.allCases, id: \.self) { candidate in
                Button {
                    withAnimation(.snappy(duration: 0.15)) { band = candidate }
                } label: {
                    Circle()
                        .fill(swatch(for: candidate))
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle()
                                .stroke(.white, lineWidth: band == candidate ? 2.5 : 0)
                        }
                        .overlay {
                            if isModified(candidate) {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 5, height: 5)
                                    .offset(y: 16)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.displayName)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func swatch(for band: ColorBand) -> Color {
        let rgb = ColorScience.rgbForHue(band.hueCenter)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private func isModified(_ band: ColorBand) -> Bool {
        if model.settings.convertToGrayscale {
            return model.settings.grayMixer[band] != 0
        }
        return model.settings.hueAdjustments[band] != 0
            || model.settings.saturationAdjustments[band] != 0
            || model.settings.luminanceAdjustments[band] != 0
    }

    private var hueGradient: LinearGradient {
        let center = band.hueCenter
        let colors = stride(from: -40.0, through: 40.0, by: 10.0).map { offset -> Color in
            let rgb = ColorScience.rgbForHue(center + offset)
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Curve

struct CurvePanel: View {
    let model: EditorModel
    @State private var channel: CurveChannel = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Channel", selection: $channel) {
                ForEach(CurveChannel.allCases) { channel in
                    Text(channel.rawValue).tag(channel)
                }
            }
            .pickerStyle(.segmented)

            CurveEditorView(
                curve: Binding(
                    get: { model.settings[keyPath: channel.keyPath] },
                    set: { model.setCurve(channel.keyPath, to: $0) }
                ),
                channel: channel,
                onEditingBegan: model.beginInteraction
            )

            Button("Reset Curve") {
                model.update(channel.keyPath, to: .linear)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)

            Divider().opacity(0.3)

            AdjustmentSection("Parametric") {
                AdjustmentSlider(
                    spec: ParameterSpec("Highlights", -100...100),
                    value: model.binding(\.parametricCurve.highlights),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: ParameterSpec("Lights", -100...100),
                    value: model.binding(\.parametricCurve.lights),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: ParameterSpec("Darks", -100...100),
                    value: model.binding(\.parametricCurve.darks),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: ParameterSpec("Shadows", -100...100),
                    value: model.binding(\.parametricCurve.shadows),
                    onEditingBegan: model.beginInteraction
                )
            }

            AdjustmentSection("Region Splits") {
                AdjustmentSlider(
                    spec: ParameterSpec("Shadow Split", 0...100, neutral: 25, showsSign: false),
                    value: model.binding(\.parametricCurve.shadowSplit),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: ParameterSpec("Midtone Split", 0...100, neutral: 50, showsSign: false),
                    value: model.binding(\.parametricCurve.midtoneSplit),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: ParameterSpec("Highlight Split", 0...100, neutral: 75, showsSign: false),
                    value: model.binding(\.parametricCurve.highlightSplit),
                    onEditingBegan: model.beginInteraction
                )
            }
        }
    }
}

// MARK: - Colour grading

struct GradingPanel: View {
    let model: EditorModel

    private enum Zone: String, CaseIterable, Identifiable {
        case shadows = "Shadows"
        case midtones = "Midtones"
        case highlights = "Highlights"
        case global = "Global"

        var id: String { rawValue }
    }

    @State private var zone: Zone = .midtones

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Zone", selection: $zone) {
                ForEach(Zone.allCases) { zone in
                    Text(zone.rawValue).tag(zone)
                }
            }
            .pickerStyle(.segmented)

            AdjustmentSlider(
                spec: EditSettings.Spec.gradeHue,
                value: model.binding(hueKeyPath),
                onEditingBegan: model.beginInteraction,
                trackGradient: fullHueGradient
            )
            AdjustmentSlider(
                spec: EditSettings.Spec.gradeSat,
                value: model.binding(satKeyPath),
                onEditingBegan: model.beginInteraction
            )
            AdjustmentSlider(
                spec: EditSettings.Spec.gradeLum,
                value: model.binding(lumKeyPath),
                onEditingBegan: model.beginInteraction
            )

            Divider().opacity(0.3)

            AdjustmentSection("Blending") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.gradeBlending,
                    value: model.binding(\.colorGrading.blending),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.gradeBalance,
                    value: model.binding(\.colorGrading.balance),
                    onEditingBegan: model.beginInteraction
                )
            }
        }
    }

    private var hueKeyPath: WritableKeyPath<EditSettings, Double> {
        switch zone {
        case .shadows: \.colorGrading.shadowHue
        case .midtones: \.colorGrading.midtoneHue
        case .highlights: \.colorGrading.highlightHue
        case .global: \.colorGrading.globalHue
        }
    }

    private var satKeyPath: WritableKeyPath<EditSettings, Double> {
        switch zone {
        case .shadows: \.colorGrading.shadowSat
        case .midtones: \.colorGrading.midtoneSat
        case .highlights: \.colorGrading.highlightSat
        case .global: \.colorGrading.globalSat
        }
    }

    private var lumKeyPath: WritableKeyPath<EditSettings, Double> {
        switch zone {
        case .shadows: \.colorGrading.shadowLum
        case .midtones: \.colorGrading.midtoneLum
        case .highlights: \.colorGrading.highlightLum
        case .global: \.colorGrading.globalLum
        }
    }

    private var fullHueGradient: LinearGradient {
        let colors = stride(from: 0.0, through: 360.0, by: 30.0).map { hue -> Color in
            let rgb = ColorScience.rgbForHue(hue)
            return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AdjustmentSection("Presence") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.texture,
                    value: model.binding(\.texture),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.clarity,
                    value: model.binding(\.clarity),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.dehaze,
                    value: model.binding(\.dehaze),
                    onEditingBegan: model.beginInteraction
                )
            }

            Divider().opacity(0.3)

            AdjustmentSection("Vignette") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.vignetteAmount,
                    value: model.binding(\.postCropVignetteAmount),
                    onEditingBegan: model.beginInteraction
                )
                if model.settings.postCropVignetteAmount != 0 {
                    AdjustmentSlider(
                        spec: EditSettings.Spec.vignetteMidpoint,
                        value: model.binding(\.postCropVignetteMidpoint),
                        onEditingBegan: model.beginInteraction
                    )
                    AdjustmentSlider(
                        spec: EditSettings.Spec.vignetteFeather,
                        value: model.binding(\.postCropVignetteFeather),
                        onEditingBegan: model.beginInteraction
                    )
                    AdjustmentSlider(
                        spec: EditSettings.Spec.vignetteRoundness,
                        value: model.binding(\.postCropVignetteRoundness),
                        onEditingBegan: model.beginInteraction
                    )
                    Picker("Style", selection: Binding(
                        get: { model.settings.postCropVignetteStyle },
                        set: { model.update(\.postCropVignetteStyle, to: $0) }
                    )) {
                        ForEach(VignetteStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider().opacity(0.3)

            AdjustmentSection("Grain") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.grainAmount,
                    value: model.binding(\.grainAmount),
                    onEditingBegan: model.beginInteraction
                )
                if model.settings.grainAmount > 0 {
                    AdjustmentSlider(
                        spec: EditSettings.Spec.grainSize,
                        value: model.binding(\.grainSize),
                        onEditingBegan: model.beginInteraction
                    )
                    AdjustmentSlider(
                        spec: EditSettings.Spec.grainFrequency,
                        value: model.binding(\.grainFrequency),
                        onEditingBegan: model.beginInteraction
                    )
                }
            }

            Divider().opacity(0.3)

            AdjustmentSection("Optics") {
                AdjustmentSlider(
                    spec: ParameterSpec("Lens Vignette", -100...100),
                    value: model.binding(\.vignetteAmount),
                    onEditingBegan: model.beginInteraction
                )
            }
        }
    }
}

// MARK: - Detail

struct DetailPanel: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AdjustmentSection("Sharpening") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.sharpness,
                    value: model.binding(\.sharpness),
                    onEditingBegan: model.beginInteraction
                )
                if model.settings.sharpness > 0 {
                    AdjustmentSlider(
                        spec: EditSettings.Spec.sharpenRadius,
                        value: model.binding(\.sharpenRadius),
                        onEditingBegan: model.beginInteraction
                    )
                    AdjustmentSlider(
                        spec: EditSettings.Spec.sharpenDetail,
                        value: model.binding(\.sharpenDetail),
                        onEditingBegan: model.beginInteraction
                    )
                    AdjustmentSlider(
                        spec: EditSettings.Spec.sharpenMasking,
                        value: model.binding(\.sharpenEdgeMasking),
                        onEditingBegan: model.beginInteraction
                    )
                }
            }

            Divider().opacity(0.3)

            AdjustmentSection("Noise Reduction") {
                AdjustmentSlider(
                    spec: EditSettings.Spec.luminanceNR,
                    value: model.binding(\.luminanceNR),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.colorNR,
                    value: model.binding(\.colorNR),
                    onEditingBegan: model.beginInteraction
                )
                AdjustmentSlider(
                    spec: EditSettings.Spec.nrSmoothness,
                    value: model.binding(\.colorNRSmoothness),
                    onEditingBegan: model.beginInteraction
                )
            }

            if model.source?.isRaw == true {
                Text("Noise reduction on raw files is applied during demosaic, where it works on the sensor data directly. Changing it re-decodes the image, so it's slower than the other sliders.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }
}
