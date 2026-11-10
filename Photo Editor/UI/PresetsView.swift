//
//  PresetsView.swift
//  Photo Editor
//
//  The preset browser: imported Adobe presets grouped the way the files
//  declare, each rendered live against the open photo.
//

import SwiftUI
import UniformTypeIdentifiers

struct PresetsView: View {
    let model: EditorModel
    let store: PresetStore

    @Environment(\.dismiss) private var dismiss

    @State private var isImporting = false
    @State private var isSaving = false
    @State private var newPresetName = ""
    @State private var newPresetGroup = ""
    @State private var exportURL: URL?
    @State private var importMessage: String?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.presets.isEmpty {
                    emptyState
                } else {
                    presetList
                }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Presets").font(.headline)
                        if !store.presets.isEmpty {
                            Text("\(store.presets.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Import from Files…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            newPresetName = suggestedName
                            newPresetGroup = "My Presets"
                            isSaving = true
                        } label: {
                            Label("Save Current Edit…", systemImage: "plus.circle")
                        }
                        .disabled(!model.hasImage || !model.isModified)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search presets")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: PresetStore.importableTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("Save Preset", isPresented: $isSaving) {
                TextField("Name", text: $newPresetName)
                TextField("Group", text: $newPresetGroup)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveCurrent() }
            } message: {
                Text("Captures every adjustment currently applied.")
            }
            .alert(
                "Import",
                isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                )
            ) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            .sheet(item: Binding(
                get: { exportURL.map(IdentifiableURL.init) },
                set: { if $0 == nil { exportURL = nil } }
            )) { wrapper in
                ShareSheet(items: [wrapper.url])
            }
        }
    }

    // MARK: - Content

    private var filteredGroups: [(group: String, presets: [Preset])] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.groupedPresets }
        return store.groupedPresets.compactMap { group in
            let matches = group.presets.filter {
                $0.name.lowercased().contains(query) || group.group.lowercased().contains(query)
            }
            return matches.isEmpty ? nil : (group: group.group, presets: matches)
        }
    }

    private var presetList: some View {
        List {
            if model.appliedPreset != nil {
                Section("Applied") {
                    amountRow
                }
            }

            ForEach(filteredGroups, id: \.group) { group in
                Section(group.group) {
                    ForEach(group.presets) { preset in
                        PresetRow(
                            preset: preset,
                            model: model,
                            isApplied: model.appliedPreset?.id == preset.id
                        ) {
                            model.apply(preset)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(preset)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                exportURL = try? store.exportURL(for: preset)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var amountRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.appliedPreset?.name ?? "")
                .font(.system(size: 14, weight: .medium))

            if let warning = model.appliedPreset?.missingLookWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 2)
            }
            AdjustmentSlider(
                spec: ParameterSpec("Amount", 0...100, neutral: 100, showsSign: false),
                value: Binding(
                    get: { model.presetAmount * 100 },
                    set: { model.setPresetAmount($0 / 100) }
                )
            )
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Presets Yet", systemImage: "camera.filters")
        } description: {
            Text("Import Adobe Camera Raw \(Text(".xmp").monospaced()) presets or legacy Lightroom \(Text(".lrtemplate").monospaced()) files from the Files app.")
        } actions: {
            Button("Import from Files…") { isImporting = true }
                .buttonStyle(.borderedProminent)
            if model.hasImage && model.isModified {
                Button("Save Current Edit…") {
                    newPresetName = suggestedName
                    newPresetGroup = "My Presets"
                    isSaving = true
                }
            }
        }
    }

    // MARK: - Actions

    private var suggestedName: String {
        "Preset \(store.presets.filter { $0.origin == .user }.count + 1)"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let summary = store.importPresets(from: urls)
            if summary.failures.isEmpty {
                importMessage = summary.isEmpty ? "Nothing to import." : summary.message
            } else {
                let details = summary.failures
                    .map { "\($0.name): \($0.reason)" }
                    .joined(separator: "\n")
                importMessage = "\(summary.message)\n\n\(details)"
            }
        case .failure(let error):
            importMessage = error.localizedDescription
        }
    }

    private func saveCurrent() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let group = newPresetGroup.trimmingCharacters(in: .whitespaces)
        store.save(model.makePreset(named: name, group: group.isEmpty ? nil : group))
    }
}

// MARK: - Row

private struct PresetRow: View {
    let preset: Preset
    let model: EditorModel
    let isApplied: Bool
    let apply: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: apply) {
            HStack(spacing: 12) {
                thumbnailView

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(preset.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if preset.missingLook != nil {
                        Label("Needs an Adobe profile", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if isApplied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task(id: preset.id) {
            // Rendered against the open photo so the thumbnail shows what the
            // preset will actually do to this image.
            thumbnail = await model.thumbnail(for: preset)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if !model.hasImage {
                Image(systemName: "camera.filters")
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(.rect(cornerRadius: 6))
    }
}

// MARK: - Share helpers

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
