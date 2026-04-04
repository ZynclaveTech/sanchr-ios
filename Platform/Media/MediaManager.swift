import AVFoundation
import Foundation
import PhotosUI
import UIKit

/// Protocol for media capture, compression, and management.
protocol MediaManagerProtocol: AnyObject, Sendable {
    /// Compresses an image to the target size and quality.
    func compressImage(_ image: UIImage, maxSizeKB: Int) async throws -> Data

    /// Compresses a video at the given URL.
    func compressVideo(at url: URL) async throws -> URL

    /// Generates a thumbnail for a video.
    func generateThumbnail(for videoURL: URL) async throws -> UIImage

    /// Saves encrypted media to the app's cache directory.
    func cacheMedia(data: Data, filename: String) async throws -> URL

    /// Clears the media cache.
    func clearCache() async throws
}

/// Manages media capture, compression, encryption, and caching.
final class MediaManager: MediaManagerProtocol, @unchecked Sendable {
    private let mediaEncryption: MediaEncryptionProtocol
    private let cacheDirectory: URL

    init(mediaEncryption: MediaEncryptionProtocol) {
        self.mediaEncryption = mediaEncryption
        self.cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sanchr_media", isDirectory: true)

        // Ensure cache directory exists
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try? (cacheDirectory as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
    }

    func compressImage(_ image: UIImage, maxSizeKB: Int) async throws -> Data {
        SanchrLogger.media.info("Compressing image to max \(maxSizeKB)KB")

        var compression: CGFloat = 0.9
        var data = image.jpegData(compressionQuality: compression) ?? Data()

        while data.count > maxSizeKB * 1024, compression > 0.1 {
            compression -= 0.1
            data = image.jpegData(compressionQuality: compression) ?? Data()
        }

        SanchrLogger.media.info("Image compressed: \(data.count) bytes at quality \(compression)")
        return data
    }

    func compressVideo(at url: URL) async throws -> URL {
        SanchrLogger.media.info("Compressing video at \(url.lastPathComponent)")

        // TODO: Implement AVAssetExportSession compression
        // let asset = AVURLAsset(url: url)
        // let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality)
        // let outputURL = cacheDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        // session?.outputURL = outputURL
        // session?.outputFileType = .mp4
        // await session?.export()

        return url
    }

    func generateThumbnail(for videoURL: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        return UIImage(cgImage: cgImage)
    }

    func cacheMedia(data: Data, filename: String) async throws -> URL {
        let fileURL = cacheDirectory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        try? (fileURL as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        return fileURL
    }

    func clearCache() async throws {
        SanchrLogger.media.info("Clearing media cache")
        let contents = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try FileManager.default.removeItem(at: url)
        }
    }
}
