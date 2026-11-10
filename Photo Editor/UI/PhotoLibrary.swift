//
//  PhotoLibrary.swift
//  Photo Editor
//
//  Direct PhotoKit access to the camera roll.
//
//  The system photo picker is privacy-preserving but only ever hands over a
//  rendered copy — for a ProRAW shot it offers `public.jpeg` and nothing else,
//  so the DNG is unreachable through it no matter how it's configured. Reading
//  the library ourselves is the only way to get the raw original, and it's
//  also what lets a RAW badge appear on thumbnails while browsing.
//

import Foundation
import Observation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class PhotoLibrary {

    enum Access: Equatable {
        case notDetermined
        case denied
        case authorized
        case limited
    }

    private(set) var access: Access = .notDetermined
    private(set) var assets: [PHAsset] = []
    private(set) var isLoading = false

    /// Whether each asset has a raw original, cached by local identifier.
    /// Resolving this touches the resource list, so it's done per visible cell
    /// rather than for the whole library up front.
    private var rawFlags: [String: Bool] = [:]

    private let imageManager = PHCachingImageManager()

    // MARK: - Authorisation

    func refreshAccess() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if access == .authorized || access == .limited { loadAssets() }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
        if access == .authorized || access == .limited { loadAssets() }
    }

    private static func map(_ status: PHAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Presents the "select more photos" sheet when access is limited.
    func presentLimitedPicker(from controller: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    // MARK: - Fetching

    func loadAssets() {
        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result = PHAsset.fetchAssets(with: options)
        var found: [PHAsset] = []
        found.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in found.append(asset) }
        assets = found
    }

    // MARK: - Raw detection

    /// True when the asset carries a raw original alongside its rendered copy.
    func hasRaw(_ asset: PHAsset) -> Bool {
        if let cached = rawFlags[asset.localIdentifier] { return cached }
        let result = Self.rawResource(for: asset) != nil
        rawFlags[asset.localIdentifier] = result
        return result
    }

    private static func rawResource(for asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first { resource in
            UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
        }
    }

    // MARK: - Thumbnails

    func thumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        // Exactly one callback. Opportunistic delivery fires repeatedly with
        // progressively better images, which would resume the continuation
        // more than once and trap.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Loading originals

    struct LoadedAsset {
        var data: Data
        var filename: String
        var typeIdentifier: String
        var isRaw: Bool
    }

    /// Fetches the best original for editing: the raw file when one exists,
    /// otherwise the primary rendered resource.
    func loadOriginal(for asset: PHAsset) async -> LoadedAsset? {
        let resources = PHAssetResource.assetResources(for: asset)
        let raw = Self.rawResource(for: asset)
        let chosen = raw
            ?? resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
        guard let chosen else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // fetch from iCloud if needed

        // The data handler is called repeatedly on a private queue, so the
        // accumulating buffer lives in a reference box rather than a local.
        let buffer = DataBox()

        let succeeded: Bool = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(
                for: chosen,
                options: options,
                dataReceivedHandler: { buffer.append($0) },
                completionHandler: { error in
                    continuation.resume(returning: error == nil)
                }
            )
        }

        guard succeeded else { return nil }
        return LoadedAsset(
            data: buffer.data,
            filename: chosen.originalFilename,
            typeIdentifier: chosen.uniformTypeIdentifier,
            isRaw: raw != nil
        )
    }
}

/// Thread-safe accumulator for PhotoKit's chunked resource delivery.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
