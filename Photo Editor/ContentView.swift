//
//  ContentView.swift
//  Photo Editor
//
//  Created by Henri Lavikainen on 6.8.2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = EditorModel()
    @State private var store = PresetStore()
    @State private var library = PhotoLibrary()

    @State private var tab: PanelTab = .light
    @State private var isOpeningFile = false

    /// One piece of state for both sheets. Two `.sheet(isPresented:)`
    /// modifiers on the same view conflict — the second one wins and the
    /// first silently never presents.
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: String, Identifiable {
        case presets, export, photos
        var id: String { rawValue }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if model.hasImage {
                editor
            } else {
                welcome
            }
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .fileImporter(
            isPresented: $isOpeningFile,
            allowedContentTypes: [.image, .rawImage],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.open(url: url) }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .presets: PresetsView(model: model, store: store)
            case .export: ExportView(model: model)
            case .photos: PhotoBrowserView(library: library, model: model)
            }
        }
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ),
            presenting: model.notice
        ) { _ in
            Button("OK") { model.notice = nil }
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(Color.accentColor)
                Text("Photo Editor")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Adobe Camera Raw adjustments and presets, on ProRAW, HEIC and JPEG.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(spacing: 12) {
                Button {
                    activeSheet = .photos
                } label: {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    isOpeningFile = true
                } label: {
                    Label("Open from Files…", systemImage: "folder")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    activeSheet = .presets
                } label: {
                    Label("Manage Presets", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }

            Spacer()

            if !CIKernelLibrary.shared.isComplete {
                Label(
                    "The Metal shader library didn't load, so adjustments won't render.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if sizeClass == .regular {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    canvas
                }
                Divider()
                VStack(spacing: 0) {
                    PanelTabBar(selection: $tab)
                        .padding(.vertical, 6)
                    Divider().opacity(0.4)
                    AdjustmentPanelView(model: model, tab: $tab)
                }
                .frame(width: 340)
                .background(.black)
            }
        } else {
            VStack(spacing: 0) {
                toolbar
                canvas
                Divider().opacity(0.4)
                presetBar
                PanelTabBar(selection: $tab)
                    .padding(.vertical, 6)
                Divider().opacity(0.4)
                AdjustmentPanelView(model: model, tab: $tab)
                    .frame(height: 250)
            }
        }
    }

    private var canvas: some View {
        ImageCanvasView(
            image: model.previewImage,
            originalImage: model.originalImage,
            isShowingOriginal: Binding(
                get: { model.isShowingOriginal },
                set: { model.isShowingOriginal = $0 }
            ),
            isRendering: model.isRendering
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Menu {
                Button {
                    activeSheet = .photos
                } label: {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    isOpeningFile = true
                } label: {
                    Label("Open from Files…", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    model.resetAll()
                } label: {
                    Label("Reset All Adjustments", systemImage: "arrow.counterclockwise")
                }
                .disabled(!model.isModified)
            } label: {
                Image(systemName: "photo.badge.plus")
            }

            VStack(spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let source = model.source {
                    HStack(spacing: 5) {
                        // RAW is called out in the accent colour because it's
                        // the difference between having highlight latitude and
                        // not — worth being able to see at a glance.
                        Text(source.formatLabel)
                            .font(.system(size: 9, weight: .bold))
                            .kerning(0.4)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                source.isRaw ? Color.accentColor : Color.secondary.opacity(0.3),
                                in: .rect(cornerRadius: 3)
                            )
                            .foregroundStyle(source.isRaw ? Color.black : Color.primary)
                        Text(subtitle(for: source))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)

            Button {
                activeSheet = .presets
            } label: {
                Image(systemName: "camera.filters")
            }

            Button {
                activeSheet = .export
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black)
    }

    /// The preset Amount strip, shown only while a preset is the active edit.
    @ViewBuilder
    private var presetBar: some View {
        if let preset = model.appliedPreset {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                    Text(preset.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Slider(value: Binding(
                        get: { model.presetAmount },
                        set: { model.setPresetAmount($0) }
                    ), in: 0...1)
                    .frame(width: 130)
                    Text("\(Int(model.presetAmount * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }

                // Say so right on the canvas, not just in the browser — this is
                // where you'd otherwise be wondering why it doesn't look right.
                if let warning = preset.missingLookWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black)
        }
    }

    private func subtitle(for source: ImageSource) -> String {
        let width = Int(source.nativeSize.width)
        let height = Int(source.nativeSize.height)
        return String(format: "%d × %d · %.1f MP", width, height, source.megapixels)
    }

    // MARK: - Loading

}

#Preview {
    ContentView()
}
