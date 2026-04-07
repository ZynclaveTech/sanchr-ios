// PhotosLibrarySource.swift
import Foundation
import Photos
import UIKit
import AVFoundation

/// Protocol boundary so unit tests can feed fake assets without touching PhotoKit.
protocol PhotosAssetLike {
    var localIdentifier: String { get }
    var creationDate: Date? { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    var mediaTypeIsVideo: Bool { get }
    var duration: TimeInterval { get }
}

extension PHAsset: PhotosAssetLike {
    var mediaTypeIsVideo: Bool { mediaType == .video }
}

struct RecentPhoto: Sendable, Identifiable, Equatable {
    let id: String
    let kind: PickedMedia.Kind
    let creationDate: Date?
    let width: Int
    let height: Int
    let durationSeconds: Double?
}

enum PhotoPermission: Sendable, Equatable { case notDetermined, denied, limited, authorized }

@MainActor
final class PhotosLibrarySource: NSObject, PHPhotoLibraryChangeObserver {

    private let imageManager = PHCachingImageManager()

    nonisolated static func makeFetchOptions() -> PHFetchOptions {
        let opts = PHFetchOptions()
        opts.fetchLimit = 60
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue,
                                     PHAssetMediaType.video.rawValue)
        return opts
    }

    nonisolated static func recentPhoto(from asset: PhotosAssetLike) -> RecentPhoto {
        RecentPhoto(
            id: asset.localIdentifier,
            kind: asset.mediaTypeIsVideo ? .video : .photo,
            creationDate: asset.creationDate,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            durationSeconds: asset.mediaTypeIsVideo ? asset.duration : nil
        )
    }

    func currentPermission() -> PhotoPermission {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .limited: return .limited
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    func requestPermission() async -> PhotoPermission {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func fetchRecents() -> [RecentPhoto] {
        let result = PHAsset.fetchAssets(with: Self.makeFetchOptions())
        var out: [RecentPhoto] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            out.append(Self.recentPhoto(from: asset))
        }
        return out
    }

    func startCaching(assetIDs: [String], targetSize: CGSize) {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        imageManager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: nil)
    }

    func stopAllCaching() { imageManager.stopCachingImagesForAllAssets() }

    func loadThumbnail(assetID: String, targetSize: CGSize) async -> UIImage? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            // .highQualityFormat fires the result handler exactly once. .opportunistic
            // can fire twice (low-res then high-res), which crashes CheckedContinuation.
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            // Defensive guard: even with .highQualityFormat, PhotoKit may invoke the
            // handler with a degraded image followed by a final one in some edge cases
            // (e.g. iCloud download progress). Resume only on the first non-degraded call.
            let resumed = ContinuationGuard()
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: opts) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                if resumed.tryConsume() {
                    cont.resume(returning: img)
                }
            }
        }
    }

    func loadPickedMedia(assetID: String) async -> PickedMedia? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject else { return nil }
        if asset.mediaType == .video {
            return await loadVideo(asset: asset)
        } else {
            return await loadPhoto(asset: asset)
        }
    }

    private func loadPhoto(asset: PHAsset) async -> PickedMedia? {
        await withCheckedContinuation { (cont: CheckedContinuation<PickedMedia?, Never>) in
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, uti, _, _ in
                guard let data else { cont.resume(returning: nil); return }
                let isHEIC = (uti ?? "").lowercased().contains("heic")
                cont.resume(returning: PickedMedia(
                    id: UUID(), kind: .photo, data: data, fileURL: nil,
                    originalFilename: asset.localIdentifier + (isHEIC ? ".heic" : ".jpg"),
                    mimeType: isHEIC ? "image/heic" : "image/jpeg",
                    width: asset.pixelWidth, height: asset.pixelHeight, durationSeconds: nil))
            }
        }
    }

    private func loadVideo(asset: PHAsset) async -> PickedMedia? {
        await withCheckedContinuation { (cont: CheckedContinuation<PickedMedia?, Never>) in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else { cont.resume(returning: nil); return }
                cont.resume(returning: PickedMedia(
                    id: UUID(), kind: .video, data: Data(), fileURL: urlAsset.url,
                    originalFilename: urlAsset.url.lastPathComponent, mimeType: "video/mp4",
                    width: asset.pixelWidth, height: asset.pixelHeight, durationSeconds: asset.duration))
            }
        }
    }

    // MARK: PHPhotoLibraryChangeObserver
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {}
}

/// One-shot guard so a PhotoKit result handler that may be invoked multiple times
/// can only resume a CheckedContinuation once. Lock-protected so it is safe from
/// any thread PhotoKit may dispatch on.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    func tryConsume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}
