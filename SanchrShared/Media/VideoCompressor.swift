@preconcurrency import AVFoundation
import Foundation

/// Re-encodes a video down to chat-appropriate size before it is uploaded.
///
/// Photos were already re-encoded to JPEG on the way out; videos were sent as
/// the camera produced them, so a 4K clip went out at full size — slow to
/// upload, expensive on the recipient's data, and heavy on their storage.
///
/// Every step is written to fail *open*: any problem returns the original
/// file. Compression is an optimisation, and a failed optimisation must never
/// cost someone their message.
public enum VideoCompressor {

    /// Returns a re-encoded copy, or the original when re-encoding is not
    /// worth it or does not succeed.
    ///
    /// The caller owns the returned URL either way and should not assume it
    /// differs from the input.
    public static func compressedForSending(_ source: URL) async -> URL {
        let asset = AVURLAsset(url: source)

        let byteCount = fileSize(of: source)
        let pixelSize = (try? await naturalPixelSize(of: asset)) ?? .zero

        switch VideoCompressionPolicy.decide(pixelSize: pixelSize, byteCount: byteCount) {
        case .sendOriginal(let reason):
            SanchrLogger.media.info(
                "Video compression skipped (\(reason)): \(byteCount) bytes"
            )
            return source
        case .compress:
            break
        }

        // 1280x720 caps the long edge while preserving aspect ratio and the
        // source's orientation transform, and re-encodes to H.264/AAC — which
        // is what makes the saving, since camera originals are barely
        // compressed.
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1280x720
        ) else {
            SanchrLogger.media.warning("Video compression unavailable for this asset; sending original")
            return source
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-compressed.mp4")
        try? FileManager.default.removeItem(at: destination)

        session.outputURL = destination
        session.outputFileType = .mp4
        // Lets the receiver start playing before the whole file has arrived.
        session.shouldOptimizeForNetworkUse = true

        await export(session)

        guard session.status == .completed,
              FileManager.default.fileExists(atPath: destination.path)
        else {
            SanchrLogger.media.warning(
                "Video compression failed (\(String(describing: session.error))); sending original"
            )
            try? FileManager.default.removeItem(at: destination)
            return source
        }

        let compressedBytes = fileSize(of: destination)
        guard VideoCompressionPolicy.isWorthKeeping(
            compressedBytes: compressedBytes,
            originalBytes: byteCount
        ) else {
            // Re-encoding can enlarge an already-compressed or very short clip.
            SanchrLogger.media.info(
                "Video compression not worth keeping (\(byteCount) -> \(compressedBytes)); sending original"
            )
            try? FileManager.default.removeItem(at: destination)
            return source
        }

        SanchrLogger.media.info(
            "Video compressed \(byteCount) -> \(compressedBytes) bytes"
        )
        return destination
    }

    // MARK: - Helpers

    private static func export(_ session: AVAssetExportSession) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
    }

    /// The video track's natural size. Orientation is deliberately ignored —
    /// the policy only compares the longer and shorter edges, so a portrait
    /// clip is judged the same as its landscape equivalent.
    private static func naturalPixelSize(of asset: AVURLAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return .zero
        }
        return try await track.load(.naturalSize)
    }

    private static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
