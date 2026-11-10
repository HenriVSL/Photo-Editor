//
//  ExportView.swift
//  Photo Editor
//
//  Full-resolution export. The render here runs with draft mode off and no
//  size limit, so it's the real thing rather than the preview pipeline.
//

import CoreGraphics
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .jpeg
    @State private var quality: Double = 0.92
    @State private var wideGamut = false
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    if format.supportsQuality {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Quality")
                                Spacer()
                                Text("\(Int(quality * 100))%")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $quality, in: 0.4...1)
                        }
                    }
                }

                Section {
                    Toggle("Display P3", isOn: $wideGamut)
                } header: {
                    Text("Colour")
                } footer: {
                    Text(wideGamut
                        ? "Keeps the wider gamut a ProRAW file can hold. Best for viewing on Apple displays."
                        : "sRGB — the safe choice for sharing anywhere.")
                }

                Section {
                    Button {
                        Task { await share() }
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        Task { await saveToPhotos() }
                    } label: {
                        Label("Save to Photos", systemImage: "photo.badge.plus")
                    }
                }
                .disabled(isExporting)

                if isExporting {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Rendering at full resolution…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let statusMessage {
                    Section { Text(statusMessage).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { exportedURL.map(IdentifiableURL.init) },
                set: { if $0 == nil { exportedURL = nil } }
            )) { wrapper in
                ShareSheet(items: [wrapper.url])
            }
        }
    }

    private var colorSpace: CGColorSpace {
        let name: CFString = wideGamut ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func share() async {
        isExporting = true
        statusMessage = nil
        defer { isExporting = false }

        guard let url = await model.exportFile(
            format: format,
            quality: quality,
            colorSpace: colorSpace
        ) else {
            statusMessage = "The export failed."
            return
        }
        exportedURL = url
    }

    private func saveToPhotos() async {
        isExporting = true
        statusMessage = nil
        defer { isExporting = false }

        guard let data = await model.exportData(
            format: format,
            quality: quality,
            colorSpace: colorSpace
        ) else {
            statusMessage = "The export failed."
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            statusMessage = "Photo library access was declined. You can still use Share."
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = uniformTypeIdentifier
                request.addResource(with: .photo, data: data, options: options)
            }
            statusMessage = "Saved to Photos."
        } catch {
            statusMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private var uniformTypeIdentifier: String {
        switch format {
        case .jpeg: UTType.jpeg.identifier
        case .heif: UTType.heic.identifier
        case .png: UTType.png.identifier
        case .tiff: UTType.tiff.identifier
        }
    }
}
