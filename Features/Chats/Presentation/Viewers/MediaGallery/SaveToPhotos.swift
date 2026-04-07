import Foundation
import Photos

/// Writes a decrypted media file to the system Photos library using
/// `.addOnly` access — we never need to read the library, only add.
/// Errors propagate to the caller so the gallery can show an alert.
enum SaveToPhotos {
    enum SaveError: LocalizedError {
        case permissionDenied
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Sanchr doesn't have permission to add items to your Photos library. Open Settings to enable it."
            case .writeFailed(let message):
                return "Couldn't save to Photos: \(message)"
            }
        }
    }

    enum MediaKind {
        case image
        case video
    }

    static func save(
        fileURL: URL,
        kind: MediaKind
    ) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        default:
            throw SaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                switch kind {
                case .image:
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                case .video:
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                }
            }, completionHandler: { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: SaveError.writeFailed(error?.localizedDescription ?? "unknown"))
                }
            })
        }
    }
}
