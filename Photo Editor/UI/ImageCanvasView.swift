//
//  ImageCanvasView.swift
//  Photo Editor
//
//  The photo canvas: pinch to zoom, drag to pan, double-tap to toggle between
//  fit and 2×, and press and hold anywhere to see the unedited original.
//

import SwiftUI

struct ImageCanvasView: View {
    let image: CGImage?
    let originalImage: CGImage?
    @Binding var isShowingOriginal: Bool
    let isRendering: Bool

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maxScale: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let displayed {
                    Image(decorative: displayed, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .gesture(magnification(in: geometry.size))
                        .simultaneousGesture(pan(in: geometry.size))
                        .onTapGesture(count: 2) { toggleZoom() }
                        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 20) {
                            // Fires on completion; the press state below drives
                            // the actual before/after toggle.
                        } onPressingChanged: { pressing in
                            withAnimation(.easeOut(duration: 0.12)) {
                                isShowingOriginal = pressing
                            }
                        }
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }

                if isShowingOriginal {
                    Text("BEFORE")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: .capsule)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                        .transition(.opacity)
                }

                if isRendering {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: .circle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isRendering)
    }

    private var displayed: CGImage? {
        isShowingOriginal ? (originalImage ?? image) : image
    }

    // MARK: - Gestures

    private func magnification(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = (committedScale * value.magnification).clamped(to: 1...maxScale)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1.01 { resetTransform() } else { clampOffset(in: size) }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1.01 else { return }
                clampOffset(in: size)
            }
    }

    private func toggleZoom() {
        withAnimation(.snappy(duration: 0.28)) {
            if scale > 1.01 {
                resetTransform()
            } else {
                scale = 2
                committedScale = 2
            }
        }
    }

    private func resetTransform() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }

    /// Keeps the image from being dragged entirely off screen.
    private func clampOffset(in size: CGSize) {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        withAnimation(.snappy(duration: 0.2)) {
            offset = CGSize(
                width: offset.width.clamped(to: -limitX...limitX),
                height: offset.height.clamped(to: -limitY...limitY)
            )
            committedOffset = offset
        }
    }
}
