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
    /// Fixed size for this bubble, overriding the aspect-derived one.
    ///
    /// Album tiles are laid out on a grid, so their size comes from the grid
    /// rather than the attachment's own shape. Reusing this view for a tile
    /// keeps one copy of the download, decrypt, cache, auto-download-policy
    /// and retry behaviour instead of a second implementation that would drift.
    var fixedSize: CGSize?
    /// Corner radius for this view's own clip.
    ///
    /// A standalone photo rounds itself. A tile inside a collage must not: the
    /// collage rounds its outer corners as a whole, and a tile that also
    /// rounded all four of its own turned an album into four separate squares
    /// instead of one picture divided up.
    var cornerRadius: CGFloat = 14
    /// Squares the bottom corners so a caption below can meet the picture.
    ///
    /// Media with a caption is one bubble: the picture on top, the text under
    /// it, the bubble rounding the outside. Rounding the picture's own bottom
    /// corners too drew a seam across the middle of it — the curve ended, the
    /// flat caption began, and the two read as separate objects stacked up
    /// rather than one message.
    var squaresBottomCorners: Bool = false

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: squaresBottomCorners ? 0 : cornerRadius,
            bottomTrailingRadius: squaresBottomCorners ? 0 : cornerRadius,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )
    }
    @Environment(DependencyContainer.self) private var container
    @State private var resolvedImage: UIImage?

    /// Seeds `resolvedImage` from the cache before the first frame.
    ///
    /// The cache was consulted inside `.task`, which runs *after* the view has
    /// been rendered once. So every time the transcript came back on screen —
    /// switching chats, returning from the gallery, coming back from another
    /// screen — each photo drew its placeholder, and only then swapped in an
    /// image that had been in memory the whole time. Nothing was downloaded
    /// twice; it simply looked like it was.
    init(
        attachment: Message.MediaAttachment,
        messageId: String,
        conversationId: String,
        isOutgoing: Bool,
        uploadProgress: Double? = nil,
        uploadLabel: String? = nil,
        fixedSize: CGSize? = nil,
        cornerRadius: CGFloat = 14,
        squaresBottomCorners: Bool = false
    ) {
        self.attachment = attachment
        self.messageId = messageId
        self.conversationId = conversationId
        self.isOutgoing = isOutgoing
        self.uploadProgress = uploadProgress
        self.uploadLabel = uploadLabel
        self.fixedSize = fixedSize
        self.cornerRadius = cornerRadius
        self.squaresBottomCorners = squaresBottomCorners
        _resolvedImage = State(
            initialValue: Self.imageCache.object(forKey: messageId as NSString)
        )
    }

    @State private var placeholderImage: UIImage?
    @State private var isDownloading = false
    @State private var loadFailed = false
    @State private var retryTick: Int = 0
    /// Set when the auto-download settings say this attachment must not be
    /// fetched on the current network. Distinct from `loadFailed`: nothing has
    /// gone wrong, we are simply waiting for the user to ask.
    @State private var deferredByPolicy = false
    /// A tap on the placeholder overrides the policy for this bubble only.
    @State private var userRequestedDownload = false
    @AppStorage("sanchr.mediaAutoSave") private var mediaAutoSave = false

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
        return cache
    }()

    private static let blurHashCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200 // Bounded — blurhash placeholders are small, but don't hoard
        return cache
    }()

    /// Shared media-cache root. MUST stay in lockstep with
    /// `MediaDownloadManager.cacheDir` — both read and write the same
    /// `<messageId>.<ext>` filenames. Previously both pointed at
    /// `.cachesDirectory/MediaMessages`, which iOS purges freely; now both
    /// point at the App Group container so bubbles keep rendering after
    /// storage pressure events.
    private static let thumbCacheDir: URL = {
        let dir = AppGroup.mediaCacheURL
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
        // Video is excluded on purpose: this feeds the still-image downsampler,
        // and a video is served from its poster instead.
        guard !attachment.mimeType.hasPrefix("video/") else { return nil }
        let filePath = Self.thumbCacheDir.appendingPathComponent(
            MediaCacheFile.fileName(messageId: messageId, mimeType: attachment.mimeType)
        )
        return FileManager.default.fileExists(atPath: filePath.path) ? filePath : nil
    }

    private var displaySize: CGSize {
        fixedSize ?? BubbleMediaLayout.displaySize(for: attachment)
    }

    private var shouldAutoSaveToPhotos: Bool {
        MediaAutoSavePolicy.shouldAutoSave(
            attachment: attachment,
            autoSaveEnabled: mediaAutoSave,
            galleryVisible: ChatMediaVisibilityStore.isVisibleInGallery(
                conversationId: conversationId),
            isOutgoing: isOutgoing
        )
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

    /// Outcome of a load attempt. `deferred` is deliberately separate from a
    /// nil/failed result so the bubble can offer "Tap to download" instead of
    /// the "Tap to retry" affordance, which would misreport a settings choice
    /// as an error.
    private enum MediaLoadOutcome {
        case image(UIImage)
        case deferred
        case failed
    }

    /// Whether the auto-download settings permit fetching this attachment on
    /// the connection we are on right now. Outgoing media is ours and already
    /// local, and an explicit tap overrides the policy for this bubble.
    private var shouldDeferDownload: Bool {
        guard !isOutgoing, !userRequestedDownload else { return false }
        return AutoDownloadPolicy.decision(
            mimeType: attachment.mimeType,
            connection: container.networkMonitor.connectionType,
            wifi: AutoDownloadSettingsStore.wifi,
            mobile: AutoDownloadSettingsStore.mobile,
            lowData: AutoDownloadSettingsStore.lowDataMode
        ) == .manual
    }

    private var deferredPlaceholderLabel: String {
        guard attachment.sizeBytes > 0 else { return "Tap to download" }
        return ByteCountFormatter.string(
            fromByteCount: attachment.sizeBytes,
            countStyle: .file
        )
    }

    var body: some View {
        ZStack {
            if let image = resolvedImage ?? placeholderImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(shape)
                    .overlay {
                        if let progress = uploadProgress, resolvedImage != nil {
                            progressOverlay(progress: progress)
                        }
                    }
            } else {
                shape
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
                        } else if deferredByPolicy {
                            // Auto-download is off for this media type on this
                            // network. Nothing failed — the user just has to
                            // opt in, the same way WhatsApp gates media on
                            // metered connections.
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(isOutgoing ? .white.opacity(0.85) : .sanchrPrimary)
                                Text(deferredPlaceholderLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(isOutgoing ? .white.opacity(0.7) : SanchrExportColors.textTertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                userRequestedDownload = true
                                deferredByPolicy = false
                                retryTick &+= 1
                            }
                            .accessibilityLabel("Media not downloaded. Tap to download.")
                            .accessibilityAddTraits(.isButton)
                        } else if loadFailed {
                            // Tap-to-retry: replaces the silent placeholder that
                            // used to leave receivers stuck when the first
                            // download failed (network blip, expired URL, etc.).
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(isOutgoing ? .white.opacity(0.85) : .sanchrPrimary)
                                Text("Tap to retry")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(isOutgoing ? .white.opacity(0.7) : SanchrExportColors.textTertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                loadFailed = false
                                retryTick &+= 1
                            }
                            .accessibilityLabel("Media download failed. Tap to retry.")
                            .accessibilityAddTraits(.isButton)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundColor(isOutgoing ? .white.opacity(0.5) : SanchrExportColors.textTertiary)
                        }
                    }
            }
        }
        .task(id: "\(mediaLoadKey)#\(retryTick)") {
            await loadImages()
        }
    }

    private func loadImages() async {
        // Reset the retry-error state on each attempt; the .task(id:) modifier
        // re-runs this on every retryTick bump so we always restart clean.
        loadFailed = false
        deferredByPolicy = false
        if let cached = Self.imageCache.object(forKey: messageId as NSString) {
            resolvedImage = cached
            return
        }

        if placeholderImage == nil, let blurHash = attachment.blurHash {
            let targetSize = displaySize
            let cacheKey = "\(blurHash)-\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
            if let cached = Self.blurHashCache.object(forKey: cacheKey) {
                placeholderImage = cached
            } else {
                let decoded = await Task.detached(priority: .utility) {
                    BubbleImagePipeline.decodeBlurHash(blurHash, size: targetSize)
                }.value
                if let decoded {
                    Self.blurHashCache.setObject(decoded, forKey: cacheKey)
                }
                placeholderImage = decoded
            }
        }

        isDownloading = true
        defer { isDownloading = false }

        switch await loadResolvedImage() {
        case .image(let image):
            Self.cacheImage(image, forKey: messageId)
            resolvedImage = image
        case .deferred:
            deferredByPolicy = true
        case .failed:
            // Only surface the retry affordance for remote attachments
            // (sanchr-media:// or https://). A missing local file URL on
            // the sender side is expected transiently while the picker
            // temp file is being copied into the App Group cache — the
            // next body pass picks it up via `cachedMediaFilePath`.
            if !attachment.url.isFileURL {
                loadFailed = true
            }
        }
    }

    private func loadResolvedImage() async -> MediaLoadOutcome {
        let scale = await MainActor.run { UIScreen.main.scale }
        let targetSize = displaySize

        if attachment.mimeType.hasPrefix("video/") {
            return await loadResolvedVideoThumbnail(scale: scale, targetSize: targetSize)
        }

        if let localURL = localImageCandidateURL() {
            return await Self.downsampledOutcome(at: localURL, to: targetSize, scale: scale)
        }

        let ext = mediaCacheExtension
        if let cached = await container.mediaDownloadManager.cachedURL(for: messageId, ext: ext) {
            return await Self.downsampledOutcome(at: cached, to: targetSize, scale: scale)
        }

        // Everything above was already on disk and costs no data. Only a real
        // network fetch is subject to the auto-download settings.
        if shouldDeferDownload { return .deferred }

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
            return await Self.downsampledOutcome(at: url, to: targetSize, scale: scale)
        } catch {
            SanchrLogger.media.error("Media download failed: \(error.localizedDescription)")
            return .failed
        }
    }

    private static func downsampledOutcome(
        at url: URL,
        to targetSize: CGSize,
        scale: CGFloat
    ) async -> MediaLoadOutcome {
        let image = await Task.detached(priority: .utility) {
            BubbleImagePipeline.downsampleImage(at: url, to: targetSize, scale: scale)
        }.value
        return image.map { .image($0) } ?? .failed
    }

    private func loadResolvedVideoThumbnail(
        scale: CGFloat,
        targetSize: CGSize
    ) async -> MediaLoadOutcome {
        if let thumbURL = localVideoThumbnailCandidateURL() {
            return await Self.downsampledOutcome(at: thumbURL, to: targetSize, scale: scale)
        }

        let ext = mediaCacheExtension
        let cachedVideoURL: URL?
        if let cached = await container.mediaDownloadManager.cachedURL(for: messageId, ext: ext) {
            cachedVideoURL = cached
        } else {
            // A video thumbnail is generated from the video itself, so there is
            // no cheap preview to fetch — producing one means pulling the whole
            // file, which is exactly what "Photos only" exists to prevent.
            if shouldDeferDownload { return .deferred }
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
                return .failed
            }
        }

        guard let cachedVideoURL else { return .failed }
        let thumb = await generateAndCacheThumb(
            from: cachedVideoURL,
            scale: scale,
            targetSize: targetSize
        )
        return thumb.map { .image($0) } ?? .failed
    }

    private func localImageCandidateURL() -> URL? {
        // Validate that the file actually exists. The sender's in-memory
        // attachment.url often points at a picker temp file that iOS can
        // clean up mid-session; returning a dead URL here made the bubble
        // render nothing instead of falling through to the cached copy
        // or the download pipeline.
        if attachment.url.isFileURL,
           FileManager.default.fileExists(atPath: attachment.url.path) {
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

    /// Must match what the writer used, which is why it is no longer derived
    /// here. See `MediaCacheFile`.
    private var mediaCacheExtension: String {
        MediaCacheFile.fileExtension(for: attachment.mimeType)
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
        .clipShape(shape)
    }
}

// MARK: - Bubble Media Layout

enum BubbleMediaLayout {
    static let maxWidth: CGFloat = 220
    static let maxHeight: CGFloat = 280

    /// Smallest dimension a bubble is allowed to render at. A panorama scaled
    /// purely by width would otherwise come out a few points tall and be
    /// unrecognisable, and an extreme portrait would become a sliver.
    static let minSide: CGFloat = 64

    static func displaySize(for attachment: Message.MediaAttachment) -> CGSize {
        guard let width = attachment.width,
              let height = attachment.height,
              width > 0,
              height > 0
        else {
            // No dimensions: fall back to a fixed shape. Until senders started
            // recording them this was every message, so every photo rendered
            // at the same guess and then shifted once the real image decoded.
            return attachment.mimeType.hasPrefix("video/")
                ? CGSize(width: maxWidth, height: maxWidth)
                : CGSize(width: maxWidth, height: 180)
        }

        let sourceSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let scale = min(maxWidth / sourceSize.width, maxHeight / sourceSize.height)
        return CGSize(
            width: max(minSide, (sourceSize.width * scale).rounded()),
            height: max(minSide, (sourceSize.height * scale).rounded())
        )
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


/// Whether received media should be copied into the system photo library.
///
/// Extracted from the view so the decision is testable on its own: it writes to
/// a location outside the app's control — for most users, iCloud — so getting it
/// wrong is not recoverable by deleting the message afterwards.
enum MediaAutoSavePolicy {
    static func shouldAutoSave(
        attachment: Message.MediaAttachment,
        autoSaveEnabled: Bool,
        galleryVisible: Bool,
        isOutgoing: Bool
    ) -> Bool {
        // View-once media is excluded unconditionally. Saving it would preserve
        // permanently what the sender chose to show once, and no later deletion
        // reaches a photo library that has already synced.
        guard attachment.isViewOnce != true else { return false }
        return autoSaveEnabled && galleryVisible && !isOutgoing
    }
}
