import Foundation
import Photos
import SanchrShared

/// Saves a file's bytes to the iOS Photos library.
///
/// Used by `VaultViewModel.requestSave` for `.photo` / `.video` items.
/// Other types (`.document`, `.audio`, `.note`) go through the Files
/// export flow, not this service.
///
/// This protocol exists primarily for testability — `VaultViewModel`
/// tests inject a spy that records calls without touching
/// `PHPhotoLibrary`. Production uses `PhotosSaver` which writes the
/// incoming bytes to a temp file and delegates to the canonical
/// `SaveToPhotos` helper so the permission + PHAssetCreationRequest
/// flow lives in exactly one place.
protocol PhotosSaving: Sendable {
    /// Requests `.addOnly` permission and adds the bytes to the Photos
    /// library as an asset of the appropriate media type.
    ///
    /// - Parameters:
    ///   - data: the plaintext bytes to save
    ///   - mediaType: `.photo` or `.video`. Other types throw
    ///     `PhotosSaverError.unsupportedMediaType`.
    ///   - suggestedFilename: used for the temp staging file so the
    ///     Photos framework can infer the correct extension/format
    ///     (HEIC, MP4, etc.).
    /// - Throws: `PhotosSaverError` for the various failure modes.
    func save(
        data: Data,
        mediaType: VaultItem.VaultItemType,
        suggestedFilename: String
    ) async throws
}

enum PhotosSaverError: LocalizedError, Sendable {
    case unsupportedMediaType(VaultItem.VaultItemType)
    case permissionDenied
    case tempWriteFailed(underlying: String)
    case saveFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMediaType(let type):
            return "Can't save a \(type.rawValue) to Photos."
        case .permissionDenied:
            return "Sanchr needs permission to add to your Photos library. Enable it in Settings → Sanchr → Photos."
        case .tempWriteFailed(let underlying):
            return "Couldn't prepare the file: \(underlying)"
        case .saveFailed(let underlying):
            return "Couldn't save to Photos: \(underlying)"
        }
    }
}

final class PhotosSaver: PhotosSaving, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func save(
        data: Data,
        mediaType: VaultItem.VaultItemType,
        suggestedFilename: String
    ) async throws {
        // Map vault types → SaveToPhotos.MediaKind. Rejecting non-media
        // types here means the caller routes through the Files export
        // flow instead.
        let kind: SaveToPhotos.MediaKind
        switch mediaType {
        case .photo:
            kind = .image
        case .video:
            kind = .video
        case .document, .audio, .note:
            throw PhotosSaverError.unsupportedMediaType(mediaType)
        }

        // Stage the bytes to a temp file. PHAssetCreationRequest's
        // file-URL-based creationRequestForAsset* methods are the
        // canonical path — they let the Photos framework sniff the
        // format natively, which is more reliable for HEIC/HEVC than
        // passing raw Data via addResource.
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("photos-save-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw PhotosSaverError.tempWriteFailed(underlying: error.localizedDescription)
        }

        let tempURL = tempDir.appendingPathComponent(suggestedFilename)
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: tempDir)
            throw PhotosSaverError.tempWriteFailed(underlying: error.localizedDescription)
        }

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // Delegate to the canonical SaveToPhotos helper. Its error
        // surface maps 1:1 to ours.
        do {
            try await SaveToPhotos.save(fileURL: tempURL, kind: kind)
            SanchrLogger.vault.info(
                "PhotosSaver: saved \(data.count) bytes as \(mediaType.rawValue)"
            )
        } catch SaveToPhotos.SaveError.permissionDenied {
            throw PhotosSaverError.permissionDenied
        } catch SaveToPhotos.SaveError.writeFailed(let underlying) {
            throw PhotosSaverError.saveFailed(underlying: underlying)
        } catch {
            throw PhotosSaverError.saveFailed(underlying: error.localizedDescription)
        }
    }
}
