import CoreGraphics
import Foundation

/// Decides whether a video is worth re-encoding, and to what.
///
/// Separated from the export itself so the judgement calls — which clips to
/// leave alone, which target to aim at — can be tested without running a real
/// transcode.
///
/// The shape follows what the mainstream messengers do: cap the long edge
/// around 720p and re-encode, because a phone camera's original is far larger
/// than anyone needs in a chat. A minute of 4K is several hundred megabytes;
/// the same clip at 720p is tens.
public enum VideoCompressionPolicy {

    /// Long edge of the target. 720p is the common ceiling: visibly fine on a
    /// phone, and roughly an order of magnitude smaller than 4K.
    public static let targetLongEdge: CGFloat = 1280

    /// Long edge in Low Data Mode. 540p is roughly half the bytes of 720p
    /// and still readable on a phone.
    public static let lowDataLongEdge: CGFloat = 960

    /// Clips at or below this are sent as they are. Re-encoding something
    /// already small wastes time and battery, and can make it *bigger* — a
    /// short clip already compressed once often grows on a second pass.
    public static let skipBelowBytes: Int64 = 2 * 1024 * 1024

    public enum Decision: Equatable {
        /// Send the original untouched.
        case sendOriginal(reason: String)
        /// Re-encode, capping the long edge at `targetLongEdge`.
        case compress
    }

    /// - Parameters:
    ///   - pixelSize: the video's natural size, before any orientation
    ///     transform. Only the longer and shorter edges matter, so a portrait
    ///     clip is treated the same as its landscape equivalent.
    ///   - byteCount: size of the source file.
    ///   - lowData: the user's Low Data Mode switch. When on, the target is
    ///     `lowDataLongEdge` and only clips that are already small and at
    ///     or below it are left alone.
    public static func decide(pixelSize: CGSize, byteCount: Int64, lowData: Bool = false) -> Decision {
        guard byteCount > 0 else {
            return .sendOriginal(reason: "unknown size")
        }
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            // Dimensions could not be read. Re-encoding blind risks making
            // things worse, and the file is still perfectly sendable.
            return .sendOriginal(reason: "unknown dimensions")
        }
        let skipBelow = lowData ? skipBelowBytes / 2 : skipBelowBytes
        if byteCount <= skipBelow {
            return .sendOriginal(reason: "already small")
        }

        let longEdge = max(pixelSize.width, pixelSize.height)
        let target = lowData ? lowDataLongEdge : targetLongEdge
        if longEdge <= target, byteCount <= skipBelow * 8 {
            // Already at or below the target resolution and not unreasonably
            // heavy for it — likely encoded sensibly already.
            return .sendOriginal(reason: "already within target")
        }
        return .compress
    }

    /// Whether the freshly encoded file is actually worth sending instead.
    ///
    /// Export can produce something larger than the source — a clip already
    /// compressed once, or a very short one where container overhead dominates.
    /// Sending that would make the feature actively harmful, so the original
    /// wins unless the new file is meaningfully smaller.
    public static func isWorthKeeping(compressedBytes: Int64, originalBytes: Int64) -> Bool {
        guard compressedBytes > 0, originalBytes > 0 else { return false }
        // A saving under a tenth is not worth the quality loss.
        return Double(compressedBytes) < Double(originalBytes) * 0.9
    }
}
