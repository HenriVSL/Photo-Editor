//
//  PhotoBrowserView.swift
//  Photo Editor
//
//  Camera roll grid with a RAW badge on every shot that has a raw original,
//  so it's clear before opening anything which photos carry the full latitude.
//

import Photos
import SwiftUI

struct PhotoBrowserView: View {
    let library: PhotoLibrary
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss

    @State private var isOpening: String?
    @State private var showRawOnly = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                switch library.access {
                case .notDetermined: permissionPrompt
                case .denied: deniedState
                case .authorized, .limited: grid
                }
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if library.access == .authorized || library.access == .limited {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showRawOnly.toggle() }
                        } label: {
                            Label("RAW only", systemImage: showRawOnly
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
        }
        .task {
            library.refreshAccess()
        }
    }

    // MARK: - Grid

    private var visibleAssets: [PHAsset] {
        showRawOnly ? library.assets.filter { library.hasRaw($0) } : library.assets
    }

    private var grid: some View {
        ScrollView {
            if library.access == .limited {
                limitedBanner
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(visibleAssets, id: \.localIdentifier) { asset in
                    PhotoCell(
                        asset: asset,
                        library: library,
                        isOpening: isOpening == asset.localIdentifier
                    )
                    .onTapGesture { open(asset) }
                }
            }
            .padding(.horizontal, 2)

            if visibleAssets.isEmpty {
                ContentUnavailableView(
                    showRawOnly ? "No RAW Photos" : "No Photos",
                    systemImage: "photo.on.rectangle",
                    description: Text(showRawOnly
                        ? "None of the photos you've shared carry a RAW original."
                        : "Nothing in the library yet.")
                )
                .padding(.top, 60)
            }
        }
    }

    private var limitedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
            Text("You've shared only some photos.")
                .font(.system(size: 13))
            Spacer()
            Button("Manage") { presentLimitedPicker() }
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Permission states

    private var permissionPrompt: some View {
        ContentUnavailableView {
            Label("Photo Library Access", systemImage: "photo.stack")
        } description: {
            Text("""
                The system picker only ever hands over a rendered JPEG copy, \
                even for ProRAW shots. Reading the library directly is the only \
                way to open the actual RAW file — and to show which photos have \
                one before you pick.
                """)
        } actions: {
            Button("Allow Access") {
                Task { await library.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var deniedState: some View {
        ContentUnavailableView {
            Label("No Library Access", systemImage: "lock")
        } description: {
            Text("Enable Photos access in Settings to open RAW files from your library. You can still open files from the Files app.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func open(_ asset: PHAsset) {
        guard isOpening == nil else { return }
        isOpening = asset.localIdentifier

        Task {
            defer { isOpening = nil }
            guard let loaded = await library.loadOriginal(for: asset) else {
                model.notice = .problem("That photo couldn't be loaded from your library.")
                return
            }
            await model.open(
                data: loaded.data,
                name: loaded.filename,
                typeIdentifier: loaded.typeIdentifier
            )
            dismiss()
        }
    }

    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController
        else { return }
        library.presentLimitedPicker(from: root)
    }
}

// MARK: - Cell

private struct PhotoCell: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let isOpening: Bool

    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if library.hasRaw(asset) {
                    Text("RAW")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.4)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: .rect(cornerRadius: 3))
                        .foregroundStyle(.black)
                        .padding(4)
                }
            }
            .overlay {
                if isOpening {
                    Rectangle().fill(.black.opacity(0.5))
                    ProgressView().tint(.white)
                }
            }
            .contentShape(.rect)
            .task(id: asset.localIdentifier) {
                let side = 200 * displayScale
                thumbnail = await library.thumbnail(
                    for: asset,
                    size: CGSize(width: side, height: side)
                )
            }
    }
}
