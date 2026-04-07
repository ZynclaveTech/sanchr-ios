import Foundation
import UniformTypeIdentifiers
import AVFoundation
import SanchrShared

/// Walks `NSItemProvider`s from the share-sheet `NSExtensionContext` and
/// produces a single normalized `SharePayload`. Enforces the 100 MB cap by
/// stat-ing each file BEFORE the rest of the extension touches it.
///
/// Type detection order is most-specific first: movie -> audio -> image ->
/// url -> plainText -> fileURL/data. This avoids misclassifying e.g. a video
/// file (which also conforms to `public.data`) as a generic file.
enum SharePayloadLoader {

    static func load(from providers: [NSItemProvider]) async throws -> SharePayload {
        guard providers.isEmpty == false else { throw SharePayloadError.nothingShared }

        if providers.count == 1 {
            return try await loadOne(providers[0])
        }

        // Multiple attachments: load each, then aggregate-cap them.
        var parts: [SharePayload] = []
        parts.reserveCapacity(providers.count)
        for provider in providers {
            parts.append(try await loadOne(provider))
        }
        let total = parts.reduce(0) { $0 + $1.sizeBytes }
        if total > SharePayload.maxSizeBytes {
            throw SharePayloadError.tooLarge(actualBytes: total)
        }
        return .multi(parts)
    }

    // MARK: - Single-provider dispatch

    private static func loadOne(_ provider: NSItemProvider) async throws -> SharePayload {
        // Order matters: more-specific types first.
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return try await loadVideo(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            return try await loadAudio(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return try await loadImage(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            // Distinguish file URLs from web URLs — file URLs should be
            // treated as files so the recipient gets the bytes, not the path.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                return try await loadFile(provider)
            }
            return try await loadURL(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return try await loadText(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            return try await loadFile(provider)
        }
        throw SharePayloadError.unsupportedType
    }

    // MARK: - Per-type loaders

    private static func loadText(_ provider: NSItemProvider) async throws -> SharePayload {
        let s = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error {
                    cont.resume(throwing: SharePayloadError.loadFailed(error.localizedDescription)); return
                }
                if let s = item as? String { cont.resume(returning: s); return }
                if let d = item as? Data, let s = String(data: d, encoding: .utf8) {
                    cont.resume(returning: s); return
                }
                cont.resume(throwing: SharePayloadError.loadFailed("not a string"))
            }
        }
        return .text(s)
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> SharePayload {
        let u = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    cont.resume(throwing: SharePayloadError.loadFailed(error.localizedDescription)); return
                }
                if let u = item as? URL { cont.resume(returning: u); return }
                cont.resume(throwing: SharePayloadError.loadFailed("not a URL"))
            }
        }
        return .url(u)
    }

    private static func loadImage(_ provider: NSItemProvider) async throws -> SharePayload {
        let url = try await loadFileRepresentation(provider, type: UTType.image.identifier)
        let size = try fileSize(at: url)
        try enforceCap(size)
        return .image(fileURL: url, sizeBytes: size)
    }

    private static func loadVideo(_ provider: NSItemProvider) async throws -> SharePayload {
        let url = try await loadFileRepresentation(provider, type: UTType.movie.identifier)
        let size = try fileSize(at: url)
        try enforceCap(size)
        let duration = try await assetDurationSeconds(url)
        return .video(fileURL: url, sizeBytes: size, durationSeconds: duration)
    }

    private static func loadAudio(_ provider: NSItemProvider) async throws -> SharePayload {
        let url = try await loadFileRepresentation(provider, type: UTType.audio.identifier)
        let size = try fileSize(at: url)
        try enforceCap(size)
        let duration = try await assetDurationSeconds(url)
        return .audio(fileURL: url, sizeBytes: size, durationSeconds: duration)
    }

    private static func loadFile(_ provider: NSItemProvider) async throws -> SharePayload {
        let typeId: String = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            ? UTType.fileURL.identifier : UTType.data.identifier
        let url = try await loadFileRepresentation(provider, type: typeId)
        let size = try fileSize(at: url)
        try enforceCap(size)
        return .file(fileURL: url, sizeBytes: size, filename: url.lastPathComponent)
    }

    // MARK: - Primitives

    /// Copies the system-supplied temp URL into the App Group media cache so
    /// the URL outlives the provider's completion handler.
    private static func loadFileRepresentation(_ provider: NSItemProvider, type: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error {
                    cont.resume(throwing: SharePayloadError.loadFailed(error.localizedDescription))
                    return
                }
                guard let url else {
                    cont.resume(throwing: SharePayloadError.loadFailed("nil URL"))
                    return
                }
                do {
                    let cacheDir = AppGroup.mediaCacheURL
                    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                    let dest = cacheDir.appendingPathComponent("share-\(UUID().uuidString)-\(url.lastPathComponent)")
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: SharePayloadError.loadFailed(error.localizedDescription))
                }
            }
        }
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func enforceCap(_ size: Int64) throws {
        if size > SharePayload.maxSizeBytes {
            throw SharePayloadError.tooLarge(actualBytes: size)
        }
    }

    private static func assetDurationSeconds(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
