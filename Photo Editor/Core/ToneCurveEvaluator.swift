//
//  ToneCurveEvaluator.swift
//  Photo Editor
//
//  Evaluates Adobe's tone curve stack and bakes it into a 1-D lookup table.
//
//  Adobe applies, in order: the parametric (region) curve, then the RGB point
//  curve, then the per-channel point curves. All three are 1-D functions of a
//  single channel, so they compose into one LUT per channel — which is what
//  the renderer uploads to the GPU.
//

import Foundation

enum ToneCurveEvaluator {

    /// Number of samples baked per channel. Adobe's curve domain is 0...255,
    /// but the render pipeline is 16-bit float, so we oversample to keep the
    /// curve smooth under strong contrast.
    static let lutSize = 1024

    // MARK: - Monotone cubic interpolation

    /// Fritsch–Carlson monotone cubic Hermite spline. Chosen over Catmull-Rom
    /// because it cannot overshoot, so a steep curve segment never introduces
    /// the inversion artefacts a plain cubic would.
    struct MonotoneSpline {
        private let xs: [Double]
        private let ys: [Double]
        private let tangents: [Double]

        init(points: [CurvePoint]) {
            // Deduplicate and sort; a curve with coincident x values is degenerate.
            var sorted = points.sorted()
            var deduped: [CurvePoint] = []
            for p in sorted where deduped.last.map({ abs($0.x - p.x) > 1e-6 }) ?? true {
                deduped.append(p)
            }
            sorted = deduped

            guard sorted.count >= 2 else {
                let y = sorted.first?.y ?? 0
                xs = [0, 255]
                ys = [y, y]
                tangents = [0, 0]
                return
            }

            xs = sorted.map(\.x)
            ys = sorted.map(\.y)

            let n = sorted.count
            var secants = [Double](repeating: 0, count: n - 1)
            for i in 0..<(n - 1) {
                let dx = xs[i + 1] - xs[i]
                secants[i] = dx > 0 ? (ys[i + 1] - ys[i]) / dx : 0
            }

            var m = [Double](repeating: 0, count: n)
            m[0] = secants[0]
            m[n - 1] = secants[n - 2]
            for i in 1..<(n - 1) {
                if secants[i - 1] * secants[i] <= 0 {
                    m[i] = 0  // local extremum: flatten to preserve monotonicity
                } else {
                    m[i] = (secants[i - 1] + secants[i]) / 2
                }
            }

            // Fritsch–Carlson clamping.
            for i in 0..<(n - 1) {
                let s = secants[i]
                if s == 0 {
                    m[i] = 0
                    m[i + 1] = 0
                    continue
                }
                let a = m[i] / s
                let b = m[i + 1] / s
                let h = a * a + b * b
                if h > 9 {
                    let t = 3 / h.squareRoot()
                    m[i] = t * a * s
                    m[i + 1] = t * b * s
                }
            }

            tangents = m
        }

        func value(at x: Double) -> Double {
            guard let first = xs.first, let last = xs.last else { return x }
            if x <= first { return ys[0] + (x - first) * tangents[0] }
            if x >= last { return ys[ys.count - 1] + (x - last) * tangents[tangents.count - 1] }

            // Binary search for the containing interval.
            var lo = 0
            var hi = xs.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if xs[mid] <= x { lo = mid } else { hi = mid }
            }

            let h = xs[hi] - xs[lo]
            guard h > 0 else { return ys[lo] }
            let t = (x - xs[lo]) / h
            let t2 = t * t
            let t3 = t2 * t

            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2

            return h00 * ys[lo] + h10 * h * tangents[lo]
                 + h01 * ys[hi] + h11 * h * tangents[hi]
        }
    }

    // MARK: - Parametric curve

    /// Builds the control points for the four-region parametric curve.
    ///
    /// Adobe anchors the curve at the three split points and lets each slider
    /// lift or drop the curve around the centre of its region. We reproduce
    /// that by placing a control point at each region centre and running the
    /// same monotone spline through them, clamping the offsets so neighbouring
    /// regions can't cross and invert the curve.
    static func parametricPoints(_ p: ParametricCurve) -> [CurvePoint] {
        guard !p.isNeutral else { return PointCurve.linear.points }

        let xShadow = p.shadowSplit / 100
        let xMid = p.midtoneSplit / 100
        let xHigh = p.highlightSplit / 100

        // Region centres in normalised input.
        let centers = [
            xShadow / 2,
            (xShadow + xMid) / 2,
            (xMid + xHigh) / 2,
            (xHigh + 1) / 2,
        ]
        let amounts = [p.shadows, p.darks, p.lights, p.highlights]

        // Maximum vertical displacement at ±100. Adobe's regions move less at
        // the extremes because there is less headroom, so scale by the distance
        // to the nearer end of the range.
        var result: [CurvePoint] = [CurvePoint(0, 0)]
        for (center, amount) in zip(centers, amounts) {
            let headroom = min(center, 1 - center)
            let shift = (amount / 100) * 0.5 * headroom
            let y = (center + shift).clamped(to: 0...1)
            result.append(CurvePoint(center * 255, y * 255))
        }
        result.append(CurvePoint(255, 255))

        // Enforce strictly increasing y so the spline stays monotone.
        for i in 1..<result.count {
            if result[i].y <= result[i - 1].y {
                result[i].y = min(255, result[i - 1].y + 0.5)
            }
        }

        return result
    }

    // MARK: - LUT baking

    /// The composed tone curve for all three channels, sampled `lutSize` times.
    /// Values are in 0...1 in Adobe's gamma-encoded curve space; the shader
    /// encodes to that space, applies the LUT, and decodes back to linear.
    struct BakedCurves {
        var red: [Float]
        var green: [Float]
        var blue: [Float]

        var isIdentity: Bool

        /// Interleaved RGBA float data ready to become a `CIImage`.
        func rgbaFloats() -> [Float] {
            var out = [Float](repeating: 1, count: red.count * 4)
            for i in 0..<red.count {
                out[i * 4 + 0] = red[i]
                out[i * 4 + 1] = green[i]
                out[i * 4 + 2] = blue[i]
                out[i * 4 + 3] = 1
            }
            return out
        }
    }

    static func bake(_ settings: EditSettings) -> BakedCurves {
        let identity = settings.parametricCurve.isNeutral
            && settings.curveRGB.isLinear
            && settings.curveRed.isLinear
            && settings.curveGreen.isLinear
            && settings.curveBlue.isLinear

        if identity {
            let ramp = (0..<lutSize).map { Float($0) / Float(lutSize - 1) }
            return BakedCurves(red: ramp, green: ramp, blue: ramp, isIdentity: true)
        }

        let parametric = MonotoneSpline(points: parametricPoints(settings.parametricCurve))
        let rgb = MonotoneSpline(points: settings.curveRGB.points)
        let channels = [
            MonotoneSpline(points: settings.curveRed.points),
            MonotoneSpline(points: settings.curveGreen.points),
            MonotoneSpline(points: settings.curveBlue.points),
        ]

        let useParametric = !settings.parametricCurve.isNeutral
        let useRGB = !settings.curveRGB.isLinear
        let useChannel = [
            !settings.curveRed.isLinear,
            !settings.curveGreen.isLinear,
            !settings.curveBlue.isLinear,
        ]

        var out = [[Float]](repeating: [Float](repeating: 0, count: lutSize), count: 3)

        for i in 0..<lutSize {
            let x = Double(i) / Double(lutSize - 1) * 255
            var v = x
            if useParametric { v = parametric.value(at: v) }
            if useRGB { v = rgb.value(at: v) }
            for c in 0..<3 {
                let cv = useChannel[c] ? channels[c].value(at: v) : v
                out[c][i] = Float((cv / 255).clamped(to: 0...1))
            }
        }

        return BakedCurves(red: out[0], green: out[1], blue: out[2], isIdentity: false)
    }

    /// Samples a curve for display in the curve editor, in 0...1 space.
    static func displaySamples(points: [CurvePoint], count: Int = 128) -> [Double] {
        let spline = MonotoneSpline(points: points)
        return (0..<count).map { i in
            let x = Double(i) / Double(count - 1) * 255
            return (spline.value(at: x) / 255).clamped(to: 0...1)
        }
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
