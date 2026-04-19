import AVFoundation
import ImageIO
import SwiftUI
import SanchrShared

// MARK: - Media Bubble Image
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

struct MediaBubbleImage: View {
    let attachment: Message.MediaAttachment
    let messageId: String
    let conversationId: String
    let isOutgoing: Bool
    var uploadProgress: Double?
    var uploadLabel: String?
    @Environment(DependencyContainer.self) private var container
    @State private var resolvedImage: UIImage?
    @State private var placeholderImage: UIImage?
    @State private var isDownloading = false
    @AppStorage("sanchr.mediaAutoSave") private var mediaAutoSave = false

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
        return cache
    }()

    private static let thumbCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MediaMessages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var thumbCachePath: URL {
        Self.thumbCacheDir.appendingPathComponent("\(messageId)_thumb.jpg")
    }

    private static func cacheImage(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        imageCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private var cachedMediaFilePath: URL? {
        let ext: String
        if attachment.mimeType.contains("png") {
            ext = "png"
        } else if attachment.mimeType.hasPrefix("video/") {
            return nil
        } else {
            ext = "jpg"
        }
        let filePath = Self.thumbCacheDir.appendingPathComponent("\(messageId).\(ext)")
        return FileManager.default.fileExists(atPath: filePath.path) ? filePath : nil
    }

    private var displaySize: CGSize {
        BubbleMediaLayout.displaySize(for: attachment)
    }

    private var shouldAutoSaveToPhotos: Bool {
        mediaAutoSave
            && ChatMediaVisibilityStore.isVisibleInGallery(conversationId: conversationId)
            && !isOutgoing
    }

    private var mediaLoadKey: String {
        [
            messageId,
            attachment.url.absoluteString,
            attachment.thumbnailURL?.absoluteString ?? "",
            attachment.mimeType,
            attachment.blurHash ?? "",
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            if let image = resolvedImage ?? placeholderImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if let progress = uploadProgress, resolvedImage != nil {
                            progressOverlay(progress: progress)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOutgoing ? Color.white.opacity(0.15) : SanchrExportColors.surfaceSoft)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay {
                        if isDownloading || uploadProgress != nil {
                            VStack(spacing: 6) {
                                ProgressView()
                                    .tint(isOutgoing ? .white : .sanchrPrimary)
                                if let label = uploadLabel {
                                    Text(label)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(isOutgoing ? .white.opacity(0.7) : SanchrExportColors.textTertiary)
                                }
                            }
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundColor(isOutgoing ? .white.opacity(0.5) : SanchrExportColors.textTertiary)
                        }
                    }
            }
        }
        .task(id: mediaLoadKey) {
            await loadImages()
        }
    }

    private func loadImages() async {
        if let cached = Self.imageCache.object(forKey: messageId as NSString) {
            resolvedImage = cached
            return
        }

        if placeholderImage == nil, let blurHash = attachment.blurHash {
            let targetSize = displaySize
            placeholderImage = await Task.detached(priority: .utility) {
                BubbleImagePipeline.decodeBlurHash(blurHash, size: targetSize)
            }.value
        }

        isDownloading = true
        defer { isDownloading = false }

        if let image = await loadResolvedImage() {
            Self.cacheImage(image, forKey: messageId)
            resolvedImage = image
        }
    }

    private func loadResolvedImage() async -> UIImage? {
        let scale = await MainActor.run { UIScreen.main.scale }
        let targetSize = displaySize

        if attachment.mimeType.hasPrefix("video/") {
            return await loadResolvedVideoThumbnail(scale: scale, targetSize: targetSize)
        }

        if let localURL = localImageCandidateURL() {
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: localURL,
                    to: targetSize,
                    scale: scale
                )
            }.value
        }

        let ext = mediaCacheExtension
        if let cached = await container.mediaDownloadManager.cachedURL(for: messageId, ext: ext) {
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: cached,
                    to: targetSize,
                    scale: scale
                )
            }.value
        }

        do {
            let url = try await container.mediaDownloadManager.download(
                messageId: messageId,
                attachment: attachment
            )
            // Auto-save newly downloaded incoming images/videos to the system Photos library.
            if shouldAutoSaveToPhotos {
                let kind: SaveToPhotos.MediaKind = attachment.mimeType.hasPrefix("video/") ? .video : .image
                try? await SaveToPhotos.save(fileURL: url, kind: kind)
            }
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: url,
                    to: targetSize,
                    scale: scale
                )
            }.value
        } catch {
            SanchrLogger.media.error("Media download failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadResolvedVideoThumbnail(scale: CGFloat, targetSize: CGSize) async -> UIImage? {
        if let thumbURL = localVideoThumbnailCandidateURL() {
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: thumbURL,
                    to: targetSize,
                    scale: scale
                )
            }.value
        }

        let ext = mediaCacheExtension
        let cachedVideoURL: URL?
        if let cached = await container.mediaDownloadManager.cachedURL(for: messageId, ext: ext) {
            cachedVideoURL = cached
        } else {
            do {
                cachedVideoURL = try await container.mediaDownloadManager.download(
                    messageId: messageId,
                    attachment: attachment
                )
                // Auto-save newly downloaded incoming video to the system Photos library.
                if shouldAutoSaveToPhotos, let videoURL = cachedVideoURL {
                    try? await SaveToPhotos.save(fileURL: videoURL, kind: .video)
                }
            } catch {
                SanchrLogger.media.error("Media download failed: \(error.localizedDescription)")
                return nil
            }
        }

        guard let cachedVideoURL else { return nil }
        return await generateAndCacheThumb(from: cachedVideoURL, scale: scale, targetSize: targetSize)
    }

    private func localImageCandidateURL() -> URL? {
        if attachment.url.isFileURL {
            return attachment.url
        }
        return cachedMediaFilePath
    }

    private func localVideoThumbnailCandidateURL() -> URL? {
        if let thumbnailURL = attachment.thumbnailURL, FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }
        if FileManager.default.fileExists(atPath: thumbCachePath.path) {
            return thumbCachePath
        }
        return nil
    }

    private var mediaCacheExtension: String {
        if attachment.mimeType.contains("png") {
            return "png"
        }
        if attachment.mimeType.hasPrefix("video/") {
            return attachment.mimeType.contains("quicktime") ? "mov" : "mp4"
        }
        return "jpg"
    }

    private func generateAndCacheThumb(from videoURL: URL, scale: CGFloat, targetSize: CGSize) async -> UIImage? {
        let destinationPath = thumbCachePath
        let thumbnail: UIImage? = await Task.detached(priority: .utility) {
            let asset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: targetSize.width * scale,
                height: targetSize.height * scale
            )
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil as UIImage?
            }

            let image = UIImage(cgImage: cgImage)
            if let jpegData = image.jpegData(compressionQuality: 0.7) {
                try? jpegData.write(to: destinationPath, options: .atomic)
            }
            return image
        }.value

        return thumbnail
    }

    private func progressOverlay(progress: Double) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)

            if let label = uploadLabel {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Bubble Media Layout

private enum BubbleMediaLayout {
    static let maxWidth: CGFloat = 220
    static let maxHeight: CGFloat = 280

    static func displaySize(for attachment: Message.MediaAttachment) -> CGSize {
        guard let width = attachment.width,
              let height = attachment.height,
              width > 0,
              height > 0
        else {
            return attachment.mimeType.hasPrefix("video/")
                ? CGSize(width: maxWidth, height: maxWidth)
                : CGSize(width: maxWidth, height: 180)
        }

        let sourceSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let scale = min(maxWidth / sourceSize.width, maxHeight / sourceSize.height)
        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }
}

// MARK: - Bubble Image Pipeline
// Visibility promoted during god-file extraction — still referenced by LinkPreviewCard in ChatDetailView.swift.

enum BubbleImagePipeline {
    static func downsampleImage(at url: URL, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return downsampleImage(from: source, to: pointSize, scale: scale)
    }

    static func downsampleImage(data: Data, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return downsampleImage(from: source, to: pointSize, scale: scale)
    }

    static func decodeBlurHash(_ blurHash: String, size: CGSize) -> UIImage? {
        let width = max(Int(size.width / 8), 24)
        let height = max(Int(size.height / 8), 24)
        return BlurHash.decode(blurHash, width: width, height: height)
    }

    private static func downsampleImage(
        from source: CGImageSource,
        to pointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
