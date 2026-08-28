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
///
/// This runs on the *send* path, not the pick path. A 4K transcode takes long
/// enough to be felt, and putting it in front of the review screen would make
/// choosing a video feel broken. Behind the upload progress bar it is work the
/// user has already accepted is happening.
public enum VideoCompressor {

    /// A video ready to upload.
    public struct Result: Equatable, Sendable {
        public let url: URL
        /// Pixel size of `url`, when it could be read. Re-encoding changes the
        /// dimensions, so an attachment staged from the original would
        /// otherwise carry numbers describing a file that no longer exists.
        public let pixelSize: CGSize?
        /// Whether `url` is a new file the caller must clean up. The original
        /// belongs to whoever staged it and must not be deleted here.
        public let isTemporary: Bool
    }

    /// Returns a re-encoded copy, or the original when re-encoding is not
    /// worth it or does not succeed.
    ///
    /// `progress` reports the transcode from 0 to 1. It is never called for a
    /// clip that is sent as-is, so a caller folding this into a wider progress
    /// bar should treat "no calls" as "this stage was instant".
    public static func compressedForSending(
        _ source: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> Result {
        let asset = AVURLAsset(url: source)

        let byteCount = fileSize(of: source)
        let pixelSize = (try? await naturalPixelSize(of: asset)) ?? .zero

        switch VideoCompressionPolicy.decide(pixelSize: pixelSize, byteCount: byteCount) {
        case .sendOriginal(let reason):
            SanchrLogger.media.info(
                "Video compression skipped (\(reason)): \(byteCount) bytes"
            )
            return Result(
                url: source,
                pixelSize: pixelSize == .zero ? nil : pixelSize,
                isTemporary: false
            )
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
            return Result(
                url: source,
                pixelSize: pixelSize == .zero ? nil : pixelSize,
                isTemporary: false
            )
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-compressed.mp4")
        try? FileManager.default.removeItem(at: destination)

        session.outputURL = destination
        session.outputFileType = .mp4
        // Lets the receiver start playing before the whole file has arrived.
        session.shouldOptimizeForNetworkUse = true

        await export(session, progress: progress)

        guard session.status == .completed,
              FileManager.default.fileExists(atPath: destination.path)
        else {
            SanchrLogger.media.warning(
                "Video compression failed (\(String(describing: session.error))); sending original"
            )
            try? FileManager.default.removeItem(at: destination)
            return Result(
                url: source,
                pixelSize: pixelSize == .zero ? nil : pixelSize,
                isTemporary: false
            )
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
            return Result(
                url: source,
                pixelSize: pixelSize == .zero ? nil : pixelSize,
                isTemporary: false
            )
        }

        SanchrLogger.media.info(
            "Video compressed \(byteCount) -> \(compressedBytes) bytes"
        )
        let compressedSize = (try? await naturalPixelSize(of: AVURLAsset(url: destination)))
            .flatMap { $0 == .zero ? nil : $0 }
        return Result(url: destination, pixelSize: compressedSize, isTemporary: true)
    }

    // MARK: - Helpers

    private static func export(
        _ session: AVAssetExportSession,
        progress: (@Sendable (Double) -> Void)?
    ) async {
        // A 4K transcode is slow enough that a progress bar frozen at zero
        // reads as a hang. `AVAssetExportSession` only exposes progress by
        // polling, so a task samples it until the export resumes us.
        let poller: Task<Void, Never>? = progress.map { report in
            Task {
                while !Task.isCancelled {
                    report(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        defer { poller?.cancel() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        progress?(1.0)
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
