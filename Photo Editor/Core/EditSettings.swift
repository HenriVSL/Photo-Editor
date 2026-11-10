//
//  EditSettings.swift
//  Photo Editor
//
//  The complete edit parameter set, modelled on Adobe Camera Raw / Lightroom
//  process version 2012 (and later). Slider ranges and neutral values match
//  Adobe's, so a parsed .xmp maps onto these fields one-to-one and an
//  `EditSettings` can be written back out as a valid Adobe preset.
//

import Foundation

// MARK: - Colour bands

/// The eight hue bands Adobe exposes in the HSL / Color Mixer and B&W panels.
enum ColorBand: Int, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    /// Hue centre in degrees. Weights ramp linearly between adjacent centres,
    /// which gives a partition of unity across the wheel.
    var hueCenter: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 285
        case .magenta: 330
        }
    }

    var displayName: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .aqua: "Aqua"
        case .blue: "Blue"
        case .purple: "Purple"
        case .magenta: "Magenta"
        }
    }

    /// The suffix Adobe uses in `crs:` keys, e.g. `HueAdjustmentOrange`.
    var xmpSuffix: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .aqua: "Aqua"
        case .blue: "Blue"
        case .purple: "Purple"
        case .magenta: "Magenta"
        }
    }
}

/// Eight per-band values, indexed by `ColorBand`.
struct BandValues: Hashable, Codable, Sendable {
    var values: [Double]

    init(repeating v: Double = 0) {
        values = Array(repeating: v, count: ColorBand.allCases.count)
    }

    subscript(band: ColorBand) -> Double {
        get { values[band.rawValue] }
        set { values[band.rawValue] = newValue }
    }

    var isNeutral: Bool { values.allSatisfy { $0 == 0 } }

    /// Flattened for shader upload.
    var floats: [Float] { values.map { Float($0) } }
}

// MARK: - White balance

enum WhiteBalanceMode: String, Codable, Sendable {
    case asShot = "As Shot"
    case custom = "Custom"
    case auto = "Auto"
    case daylight = "Daylight"
    case cloudy = "Cloudy"
    case shade = "Shade"
    case tungsten = "Tungsten"
    case fluorescent = "Fluorescent"
    case flash = "Flash"

    /// Kelvin / tint the fixed presets correspond to for raw files.
    var fixedTemperature: (temp: Double, tint: Double)? {
        switch self {
        case .daylight: (5500, 10)
        case .cloudy: (6500, 10)
        case .shade: (7500, 10)
        case .tungsten: (2850, 0)
        case .fluorescent: (3800, 21)
        case .flash: (5500, 0)
        case .asShot, .custom, .auto: nil
        }
    }
}

// MARK: - Tone curve

/// A control point in Adobe's native 0...255 curve domain.
struct CurvePoint: Hashable, Codable, Sendable, Comparable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    static func < (lhs: CurvePoint, rhs: CurvePoint) -> Bool { lhs.x < rhs.x }
}

/// The four-zone parametric curve (Highlights / Lights / Darks / Shadows plus
/// the three split points that define where the zones meet).
struct ParametricCurve: Hashable, Codable, Sendable {
    var highlights: Double = 0      // -100...100
    var lights: Double = 0
    var darks: Double = 0
    var shadows: Double = 0
    var shadowSplit: Double = 25    // 0...100
    var midtoneSplit: Double = 50
    var highlightSplit: Double = 75

    static let identity = ParametricCurve()
    var isNeutral: Bool { self == .identity }
}

/// A point curve. An empty or two-point 0,0-255,255 curve is the identity.
struct PointCurve: Hashable, Codable, Sendable {
    var points: [CurvePoint]

    static let linear = PointCurve(points: [CurvePoint(0, 0), CurvePoint(255, 255)])

    init(points: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(255, 255)]) {
        self.points = points.sorted()
    }

    var isLinear: Bool {
        guard points.count >= 2 else { return true }
        // Linear if every point sits on y = x.
        return points.allSatisfy { abs($0.x - $0.y) < 0.5 }
    }
}

// MARK: - Colour grading

/// PV2012's three-way colour grading (which supersedes, and is stored
/// alongside, the older Split Toning controls).
struct ColorGrading: Hashable, Codable, Sendable {
    var shadowHue: Double = 0        // 0...360
    var shadowSat: Double = 0        // 0...100
    var shadowLum: Double = 0        // -100...100
    var midtoneHue: Double = 0
    var midtoneSat: Double = 0
    var midtoneLum: Double = 0
    var highlightHue: Double = 0
    var highlightSat: Double = 0
    var highlightLum: Double = 0
    var globalHue: Double = 0
    var globalSat: Double = 0
    var globalLum: Double = 0
    var blending: Double = 50        // 0...100
    var balance: Double = 0          // -100...100

    static let identity = ColorGrading()

    var isNeutral: Bool {
        shadowSat == 0 && midtoneSat == 0 && highlightSat == 0 && globalSat == 0
            && shadowLum == 0 && midtoneLum == 0 && highlightLum == 0 && globalLum == 0
    }
}

// MARK: - Raw rendering

/// How a raw file is rendered before any slider touches it — the equivalent
/// of Lightroom's Profile control.
enum RawRendering: String, Codable, Sendable, CaseIterable {
    /// The rendering that matches Lightroom, which differs by camera:
    /// Apple ProRAW files carry Apple's own embedded profile and need nothing
    /// on top, while every other raw gets a measured curve to lift it out of
    /// CIRAWFilter's much flatter generic rendering.
    case cameraMatch = "Camera"

    /// Linear sensor data with a neutral base curve of our own. Flatter, but
    /// nothing has been tone-mapped yet, so exposure and highlight recovery
    /// have the full raw latitude to work with.
    case neutral = "Neutral"

    var detail: String {
        switch self {
        case .cameraMatch:
            "The camera's own rendering, matched to Lightroom."
        case .neutral:
            "Flat and untouched. More latitude for exposure and highlight recovery."
        }
    }
}

// MARK: - Vignette

enum VignetteStyle: Int, Codable, Sendable, CaseIterable {
    case highlightPriority = 1
    case colorPriority = 2
    case paintOverlay = 3

    var displayName: String {
        switch self {
        case .highlightPriority: "Highlight Priority"
        case .colorPriority: "Color Priority"
        case .paintOverlay: "Paint Overlay"
        }
    }
}

// MARK: - Edit settings

/// Every adjustment the renderer understands. Neutral defaults equal Adobe's
/// zeroed develop state, so `EditSettings()` renders the image unmodified
/// apart from the raw default rendering.
struct EditSettings: Hashable, Codable, Sendable {

    // MARK: White balance
    var whiteBalanceMode: WhiteBalanceMode = .asShot
    /// Absolute white balance in Kelvin, for raw files only. Adobe writes this
    /// as `crs:Temperature`.
    var temperature: Double = 0
    var tint: Double = 0             // -150...150
    /// True when `temperature` holds a Kelvin value rather than a relative offset.
    var isRawTemperature: Bool = false

    /// Base rendering for raw files. Ignored for JPEG/HEIC, which already
    /// carry a baked-in rendering.
    var rawRendering: RawRendering = .cameraMatch

    /// Relative white balance shift, -100...100, which Adobe stores as
    /// `crs:IncrementalTemperature` / `crs:IncrementalTint`.
    ///
    /// This is what a preset uses when it wants to warm or cool *whatever* the
    /// image's own white balance happens to be, rather than pin it to a Kelvin
    /// value — so it applies to raw and rendered files alike, on top of the
    /// absolute setting. Most presets in circulation use this form, and it's
    /// the only white balance a preset authored against a JPEG can carry.
    var incrementalTemperature: Double = 0
    var incrementalTint: Double = 0

    // MARK: Camera calibration
    //
    // Adobe's Calibration panel, which shifts where the red, green and blue
    // primaries sit before everything downstream. It's the mechanism behind
    // most "teal and orange" looks, so ignoring it makes those presets render
    // conspicuously wrong.
    var shadowTint: Double = 0       // -100...100, green ↔ magenta in the shadows
    var redHue: Double = 0           // -100...100
    var redSaturation: Double = 0
    var greenHue: Double = 0
    var greenSaturation: Double = 0
    var blueHue: Double = 0
    var blueSaturation: Double = 0

    /// True when the Calibration panel is doing nothing.
    var isCalibrationNeutral: Bool {
        redHue == 0 && redSaturation == 0
            && greenHue == 0 && greenSaturation == 0
            && blueHue == 0 && blueSaturation == 0
    }

    // MARK: Light
    var exposure: Double = 0         // -5...+5 EV
    var contrast: Double = 0         // -100...100
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0

    // MARK: Presence
    var texture: Double = 0          // -100...100
    var clarity: Double = 0
    var dehaze: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0

    // MARK: Tone curve
    var parametricCurve = ParametricCurve()
    var curveRGB = PointCurve.linear
    var curveRed = PointCurve.linear
    var curveGreen = PointCurve.linear
    var curveBlue = PointCurve.linear

    // MARK: Colour mixer / B&W
    var convertToGrayscale = false
    var hueAdjustments = BandValues()        // -100...100
    var saturationAdjustments = BandValues()
    var luminanceAdjustments = BandValues()
    /// B&W channel mixer, used when `convertToGrayscale` is true.
    var grayMixer = BandValues()

    // MARK: Colour grading
    var colorGrading = ColorGrading()

    // MARK: Detail
    var sharpness: Double = 0            // 0...150
    var sharpenRadius: Double = 1.0      // 0.5...3.0
    var sharpenDetail: Double = 25       // 0...100
    var sharpenEdgeMasking: Double = 0   // 0...100
    var luminanceNR: Double = 0          // 0...100
    var luminanceNRDetail: Double = 50
    var luminanceNRContrast: Double = 0
    var colorNR: Double = 25             // 0...100
    var colorNRDetail: Double = 50
    var colorNRSmoothness: Double = 50

    // MARK: Effects
    var postCropVignetteAmount: Double = 0     // -100...100
    var postCropVignetteMidpoint: Double = 50  // 0...100
    var postCropVignetteFeather: Double = 50
    var postCropVignetteRoundness: Double = 0  // -100...100
    var postCropVignetteStyle: VignetteStyle = .highlightPriority
    var postCropVignetteHighlightContrast: Double = 0
    var grainAmount: Double = 0                // 0...100
    var grainSize: Double = 25                 // 0...100
    var grainFrequency: Double = 50            // 0...100

    // MARK: Optics
    var vignetteAmount: Double = 0             // lens vignette, -100...100

    static let neutral = EditSettings()

    var isNeutral: Bool { self == EditSettings() }
}

// MARK: - Parameter metadata

/// Describes one slider: its range, neutral value and how it's labelled.
/// Used by the UI so panels stay in sync with the model, and by the XMP
/// writer to decide what's worth emitting.
struct ParameterSpec: Sendable {
    let title: String
    let range: ClosedRange<Double>
    let neutral: Double
    /// Decimal places shown in the readout.
    let precision: Int
    /// Whether the readout carries an explicit `+`. True for sliders that run
    /// either side of a neutral, false for 0-based amounts and Kelvin.
    let showsSign: Bool

    init(
        _ title: String,
        _ range: ClosedRange<Double>,
        neutral: Double = 0,
        precision: Int = 0,
        showsSign: Bool? = nil
    ) {
        self.title = title
        self.range = range
        self.neutral = neutral
        self.precision = precision
        self.showsSign = showsSign ?? (range.lowerBound < neutral && neutral < range.upperBound)
    }

    /// The neutral's position along the track, 0...1.
    var neutralFraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (neutral - range.lowerBound) / span : 0
    }

    func format(_ value: Double) -> String {
        let scale = pow(10, Double(precision))
        let rounded = (value * scale).rounded() / scale
        if !showsSign {
            return precision == 0
                ? String(Int(rounded))
                : String(format: "%.\(precision)f", rounded)
        }
        if precision == 0 {
            let i = Int(rounded)
            return i > 0 ? "+\(i)" : "\(i)"
        }
        return String(format: "%+.\(precision)f", rounded)
    }
}

extension EditSettings {
    enum Spec {
        static let exposure = ParameterSpec("Exposure", -5...5, precision: 2)
        static let contrast = ParameterSpec("Contrast", -100...100)
        static let highlights = ParameterSpec("Highlights", -100...100)
        static let shadows = ParameterSpec("Shadows", -100...100)
        static let whites = ParameterSpec("Whites", -100...100)
        static let blacks = ParameterSpec("Blacks", -100...100)

        static let texture = ParameterSpec("Texture", -100...100)
        static let clarity = ParameterSpec("Clarity", -100...100)
        static let dehaze = ParameterSpec("Dehaze", -100...100)
        static let vibrance = ParameterSpec("Vibrance", -100...100)
        static let saturation = ParameterSpec("Saturation", -100...100)

        static let tempKelvin = ParameterSpec("Temp", 2000...50000, neutral: 5500, showsSign: false)
        static let tempRelative = ParameterSpec("Temp", -100...100)
        static let tintRaw = ParameterSpec("Tint", -150...150)
        static let tintRelative = ParameterSpec("Tint", -100...100)

        static let shadowTint = ParameterSpec("Shadow Tint", -100...100)
        static let primaryHue = ParameterSpec("Hue", -100...100)
        static let primarySaturation = ParameterSpec("Saturation", -100...100)

        static let bandHue = ParameterSpec("Hue", -100...100)
        static let bandSaturation = ParameterSpec("Saturation", -100...100)
        static let bandLuminance = ParameterSpec("Luminance", -100...100)
        static let grayMix = ParameterSpec("Gray Mix", -100...100)

        static let sharpness = ParameterSpec("Sharpening", 0...150)
        static let sharpenRadius = ParameterSpec("Radius", 0.5...3.0, neutral: 1.0, precision: 1, showsSign: false)
        static let sharpenDetail = ParameterSpec("Detail", 0...100, neutral: 25, showsSign: false)
        static let sharpenMasking = ParameterSpec("Masking", 0...100)
        static let luminanceNR = ParameterSpec("Noise Reduction", 0...100)
        static let nrDetail = ParameterSpec("Detail", 0...100, neutral: 50, showsSign: false)
        static let nrContrast = ParameterSpec("Contrast", 0...100)
        static let colorNR = ParameterSpec("Color Noise", 0...100, neutral: 25, showsSign: false)
        static let nrSmoothness = ParameterSpec("Smoothness", 0...100, neutral: 50, showsSign: false)

        static let vignetteAmount = ParameterSpec("Amount", -100...100)
        static let vignetteMidpoint = ParameterSpec("Midpoint", 0...100, neutral: 50, showsSign: false)
        static let vignetteFeather = ParameterSpec("Feather", 0...100, neutral: 50, showsSign: false)
        static let vignetteRoundness = ParameterSpec("Roundness", -100...100)
        static let vignetteHighlights = ParameterSpec("Highlights", 0...100)

        static let grainAmount = ParameterSpec("Amount", 0...100)
        static let grainSize = ParameterSpec("Size", 0...100, neutral: 25, showsSign: false)
        static let grainFrequency = ParameterSpec("Roughness", 0...100, neutral: 50, showsSign: false)

        static let gradeHue = ParameterSpec("Hue", 0...360)
        static let gradeSat = ParameterSpec("Saturation", 0...100)
        static let gradeLum = ParameterSpec("Luminance", -100...100)
        static let gradeBlending = ParameterSpec("Blending", 0...100, neutral: 50, showsSign: false)
        static let gradeBalance = ParameterSpec("Balance", -100...100)

        static let parametric = ParameterSpec("", -100...100)
    }
}
