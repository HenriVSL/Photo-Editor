//
//  AdjustmentSlider.swift
//  Photo Editor
//
//  The slider row used throughout the adjustment panels.
//
//  Behaves the way Lightroom's do: the track fills from the parameter's
//  neutral rather than from the left edge, so you can see at a glance which
//  direction a value has been pushed, and double-tapping resets it.
//

import SwiftUI

struct AdjustmentSlider: View {
    let spec: ParameterSpec
    @Binding var value: Double

    /// Called once when a drag starts, so the whole gesture is a single
    /// undo step rather than one per pixel of movement.
    var onEditingBegan: () -> Void = {}

    /// Optional gradient drawn behind the track — used for hue and
    /// temperature sliders where the colour is the point.
    var trackGradient: LinearGradient?

    /// What a touch turned out to be. Decided once per gesture and then left
    /// alone, so a drag can't switch between scrolling and sliding halfway.
    private enum DragPhase {
        case idle
        case sliding
        case scrolling   // handed to the enclosing ScrollView; ignore it
    }

    @State private var dragPhase: DragPhase = .idle
    @State private var valueAtEngage: Double = 0
    @State private var translationAtEngage: CGFloat = 0

    private var isDragging: Bool { dragPhase == .sliding }

    private let trackHeight: CGFloat = 3
    private let knobSize: CGFloat = 20
    /// Extra slop around the knob so it can be grabbed without precision.
    private let knobGrabRadius: CGFloat = 24
    /// How far a touch travels before we judge what it is.
    private let intentThreshold: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(spec.format(value))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isModified ? Color.accentColor : .secondary)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                let usable = max(width - knobSize, 1)
                let fraction = self.fraction(for: value)
                let neutralX = knobSize / 2 + usable * spec.neutralFraction
                let knobX = knobSize / 2 + usable * fraction

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: trackHeight)
                        .overlay {
                            if let trackGradient {
                                Capsule().fill(trackGradient).frame(height: trackHeight)
                            }
                        }

                    // Filled segment between neutral and the current value.
                    if trackGradient == nil {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: abs(knobX - neutralX), height: trackHeight)
                            .offset(x: min(knobX, neutralX))
                    }

                    // Neutral tick, only where it isn't at the very end.
                    if spec.neutralFraction > 0.02, spec.neutralFraction < 0.98 {
                        Capsule()
                            .fill(.tertiary)
                            .frame(width: 1.5, height: 9)
                            .offset(x: neutralX - 0.75)
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.35), radius: isDragging ? 5 : 2, y: 1)
                        .scaleEffect(isDragging ? 1.15 : 1)
                        .offset(x: knobX - knobSize / 2)
                        .animation(.interactiveSpring(duration: 0.18), value: isDragging)
                }
                .frame(height: knobSize)
                .contentShape(.rect)
                // Simultaneous, so a vertical drag still reaches the panel's
                // ScrollView. The phase check below is what stops this from
                // also moving the value while you scroll.
                .simultaneousGesture(
                    DragGesture(minimumDistance: intentThreshold)
                        .onChanged { gesture in
                            switch dragPhase {
                            case .scrolling:
                                return   // already conceded to the ScrollView

                            case .idle:
                                // Grabbing the knob is always a slide, however
                                // the finger then moves. Starting elsewhere on
                                // the row only counts once the movement is
                                // clearly sideways, so a scroll passes through.
                                let onKnob = abs(gesture.startLocation.x - knobX) <= knobGrabRadius
                                let sideways = abs(gesture.translation.width)
                                    > abs(gesture.translation.height)

                                guard onKnob || sideways else {
                                    dragPhase = .scrolling
                                    return
                                }

                                dragPhase = .sliding
                                valueAtEngage = value
                                // Anchor here so the value doesn't lurch by the
                                // threshold distance the moment it engages.
                                translationAtEngage = gesture.translation.width
                                onEditingBegan()

                            case .sliding:
                                break
                            }

                            // Relative, not absolute: the value moves with the
                            // finger from wherever it already was, so touching
                            // the row never snaps it somewhere new. Dragging
                            // the full track width still spans the full range.
                            let travelled = gesture.translation.width - translationAtEngage
                            let span = spec.range.upperBound - spec.range.lowerBound
                            value = quantise(valueAtEngage + travelled / usable * span)
                        }
                        .onEnded { _ in dragPhase = .idle }
                )
            }
            .frame(height: knobSize)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            onEditingBegan()
            withAnimation(.snappy(duration: 0.2)) { value = spec.neutral }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.title)
        .accessibilityValue(spec.format(value))
        .accessibilityAdjustableAction { direction in
            let step = (spec.range.upperBound - spec.range.lowerBound) / 100
            onEditingBegan()
            switch direction {
            case .increment: value = (value + step).clamped(to: spec.range)
            case .decrement: value = (value - step).clamped(to: spec.range)
            default: break
            }
        }
    }

    private var isModified: Bool {
        abs(value - spec.neutral) > 1e-6
    }

    private func fraction(for value: Double) -> Double {
        let span = spec.range.upperBound - spec.range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - spec.range.lowerBound) / span).clamped(to: 0...1)
    }

    /// Clamps, snaps near the neutral so it can be hit exactly by hand, and
    /// rounds to the precision the readout shows so the two never disagree.
    private func quantise(_ raw: Double) -> Double {
        let span = spec.range.upperBound - spec.range.lowerBound
        let clamped = raw.clamped(to: spec.range)

        let snapDistance = span * 0.012
        if abs(clamped - spec.neutral) < snapDistance { return spec.neutral }

        let scale = pow(10, Double(spec.precision))
        return ((clamped * scale).rounded() / scale).clamped(to: spec.range)
    }
}

// MARK: - Section chrome

/// A titled group of sliders, matching the collapsible panels in Camera Raw.
struct AdjustmentSection<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder var content: Content

    @State private var isExpanded = true

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.6)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
                if let trailing { trailing }
            }

            if isExpanded {
                VStack(spacing: 6) {
                    content
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
    }
}
