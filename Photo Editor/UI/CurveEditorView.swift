//
//  CurveEditorView.swift
//  Photo Editor
//
//  Interactive point curve editor over Adobe's 0...255 domain.
//
//  Drag a point to move it, tap empty space to add one, double-tap a point to
//  remove it. The endpoints stay pinned to the left and right edges, which is
//  the same constraint Camera Raw imposes.
//

import SwiftUI

enum CurveChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case red = "Red"
    case green = "Green"
    case blue = "Blue"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    var keyPath: WritableKeyPath<EditSettings, PointCurve> {
        switch self {
        case .rgb: \.curveRGB
        case .red: \.curveRed
        case .green: \.curveGreen
        case .blue: \.curveBlue
        }
    }
}

struct CurveEditorView: View {
    @Binding var curve: PointCurve
    var channel: CurveChannel = .rgb
    var onEditingBegan: () -> Void = {}

    @State private var draggingIndex: Int?

    private static let canvasSpace = "curveCanvas"

    /// How close a tap must be, in curve units, to count as hitting an
    /// existing point rather than empty canvas.
    private let grabRadius: Double = 22

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let samples = ToneCurveEvaluator.displaySamples(points: curve.points, count: 96)

            ZStack {
                grid(in: size)

                // The curve itself.
                Path { path in
                    for (index, y) in samples.enumerated() {
                        let x = Double(index) / Double(samples.count - 1)
                        let point = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(channel.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                // Control points. The drag gesture lives on each point rather
                // than on the canvas, so the rest of the square stays free for
                // the panel's ScrollView — a canvas-wide drag would make this
                // a 320pt dead zone you can't scroll past.
                ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(channel.tint, lineWidth: 2))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .scaleEffect(draggingIndex == index ? 1.35 : 1)
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                        .position(position(of: point, in: size))
                        .gesture(drag(index: index, in: size))
                        .animation(.interactiveSpring(duration: 0.15), value: draggingIndex)
                }
            }
            .coordinateSpace(.named(Self.canvasSpace))
            .background(.black.opacity(0.25))
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(.rect)
            .onTapGesture(count: 2) { location in
                removePoint(near: location, in: size)
            }
            .onTapGesture { location in
                addPoint(at: location, in: size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Drawing

    private func grid(in size: CGSize) -> some View {
        ZStack {
            Path { path in
                for i in 1..<4 {
                    let f = CGFloat(i) / 4
                    path.move(to: CGPoint(x: f * size.width, y: 0))
                    path.addLine(to: CGPoint(x: f * size.width, y: size.height))
                    path.move(to: CGPoint(x: 0, y: f * size.height))
                    path.addLine(to: CGPoint(x: size.width, y: f * size.height))
                }
            }
            .stroke(.white.opacity(0.10), lineWidth: 0.5)

            // Identity reference.
            Path { path in
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: 0))
            }
            .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func position(of point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: point.x / 255 * size.width,
            y: (1 - point.y / 255) * size.height
        )
    }

    private func curveValue(at location: CGPoint, in size: CGSize) -> CurvePoint {
        CurvePoint(
            (location.x / size.width * 255).clamped(to: 0...255),
            ((1 - location.y / size.height) * 255).clamped(to: 0...255)
        )
    }

    // MARK: - Editing

    /// Drag for one control point. Reported in the canvas coordinate space,
    /// because the gesture is attached to the small circle rather than the
    /// canvas and its own space would be meaningless here.
    private func drag(index: Int, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { gesture in
                if draggingIndex != index {
                    onEditingBegan()
                    draggingIndex = index
                }

                let target = curveValue(at: gesture.location, in: size)
                var points = curve.points
                guard index < points.count else { return }

                // Endpoints slide vertically only; interior points stay between
                // their neighbours so the curve can't fold over itself.
                if index == 0 {
                    points[0] = CurvePoint(0, target.y)
                } else if index == points.count - 1 {
                    points[index] = CurvePoint(255, target.y)
                } else {
                    let lower = points[index - 1].x + 1
                    let upper = points[index + 1].x - 1
                    points[index] = CurvePoint(target.x.clamped(to: lower...max(lower, upper)), target.y)
                }
                curve = PointCurve(points: points)
            }
            .onEnded { _ in draggingIndex = nil }
    }

    private func nearestPointIndex(to target: CurvePoint) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, point) in curve.points.enumerated() {
            let dx = point.x - target.x
            let dy = point.y - target.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= grabRadius, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func addPoint(at location: CGPoint, in size: CGSize) {
        let target = curveValue(at: location, in: size)
        guard nearestPointIndex(to: target) == nil, curve.points.count < 16 else { return }
        onEditingBegan()

        var points = curve.points
        points.append(target)
        curve = PointCurve(points: points)
    }

    private func removePoint(near location: CGPoint, in size: CGSize) {
        let target = curveValue(at: location, in: size)
        guard let index = nearestPointIndex(to: target),
              index > 0, index < curve.points.count - 1
        else { return }
        onEditingBegan()

        var points = curve.points
        points.remove(at: index)
        curve = PointCurve(points: points)
    }
}
