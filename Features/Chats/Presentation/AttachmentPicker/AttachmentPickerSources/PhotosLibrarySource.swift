// PhotosLibrarySource.swift
import Foundation
import Photos
import UIKit
import AVFoundation
import SanchrShared

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
    private let assetCache = PHAssetCache()

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
        var assets: [PHAsset] = []
        out.reserveCapacity(result.count)
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            out.append(Self.recentPhoto(from: asset))
            assets.append(asset)
        }
        // Seed the in-memory PHAsset cache so per-cell thumbnail loads
        // skip a fetchAssets round-trip (major cause of strip scroll
        // lag) and start the PHCachingImageManager prefetch at cell
        // size so thumbnails are ready the instant a cell comes on
        // screen.
        assetCache.replace(with: assets)
        imageManager.stopCachingImagesForAllAssets()
        imageManager.startCachingImages(
            for: assets,
            targetSize: CGSize(width: 112, height: 112),
            contentMode: .aspectFill,
            options: nil
        )
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
        guard let asset = assetCache.asset(forLocalIdentifier: assetID) else {
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let opts = PHImageRequestOptions()
            // `.opportunistic` fires a quick low-res callback first (served
            // instantly from PHCachingImageManager if warm) and optionally a
            // final high-res callback later. We only care about the first
            // non-nil image for a 112pt strip cell — no one can tell the
            // difference at that size. The ContinuationGuard ensures the
            // continuation is only resumed once even if PhotoKit fires
            // multiple callbacks.
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            let resumed = ContinuationGuard()
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                guard let img else { return }
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
        // Export via PHAssetResourceManager.writeData rather than handing
        // back a raw PhotoKit AVURLAsset URL. Raw URLs live inside the
        // Photos sandbox, can be ephemeral, and fail to copy for slo-mo
        // or iCloud-backed videos. writeData gives us a real local file
        // that the send pipeline owns end-to-end.
        //
        // Runs off the main actor because the file write can be slow
        // (large videos). Callers that are @MainActor-isolated will hop
        // back to main after the await.
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: {
            $0.type == .video || $0.type == .fullSizeVideo
        }) else {
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        // PHAssetResourceManager.writeData is callback-based; wrap in a
        // continuation. The guard serializes the resume in case Photos
        // fires the completion handler twice (defensive).
        let guardBox = ContinuationGuard()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default()
                    .writeData(for: videoResource, toFile: tempURL, options: options) { error in
                        guard guardBox.tryConsume() else { return }
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume() }
                    }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        guard fileSize > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        return PickedMedia(
            id: UUID(),
            kind: .video,
            data: Data(),
            fileURL: tempURL,
            originalFilename: videoResource.originalFilename,
            mimeType: "video/mp4",
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            durationSeconds: asset.duration
        )
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

/// In-memory lookup from `PHAsset.localIdentifier` → `PHAsset` so the
/// recents strip's per-cell thumbnail load doesn't need to call
/// `PHAsset.fetchAssets(withLocalIdentifiers:)` on every scroll tick.
/// Seeded from `fetchRecents` and replaced wholesale on each refresh.
@MainActor
private final class PHAssetCache {
    private var storage: [String: PHAsset] = [:]

    func replace(with assets: [PHAsset]) {
        storage = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
    }

    func asset(forLocalIdentifier id: String) -> PHAsset? {
        storage[id]
    }
}
