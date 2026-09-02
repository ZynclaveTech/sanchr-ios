import Foundation
import SanchrShared

/// Seam around the existing `MediaDownloadManager` so viewer code can be
/// unit-tested without a gRPC client, and so the document path can add a
/// filename-preserving hard link for `QLPreviewController` without
/// mutating the shared download cache.
///
/// The underlying `MediaDownloadManager.download` returns a file under
/// `<cache>/MediaMessages/<messageId>.<ext>`. That URL is fine for the
/// gallery (images + video `AVAsset` loading) but QuickLook surfaces the
/// last path component as the display title, so a PDF called
/// "Invoice Q4.pdf" would render as "msg-7.pdf" instead.
/// `decryptedURLWithDisplayName` fixes this by hard-linking the cached
/// file into a per-message display directory under its original filename.
/// Hard link, not copy — zero extra bytes on disk, and link creation is
/// atomic.
protocol ChatMediaResolving: Sendable {
    /// Returns the decrypted local file URL for an image / video. Honors
    /// the shared `MediaDownloadManager` cache and in-flight coalescing.
    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL

    /// Returns a local file URL whose last path component is the original
    /// attachment filename (if present). Used by the document viewer so
    /// `QLPreviewController` surfaces the user-facing title.
    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL
}

/// Thin protocol matching the subset of `MediaDownloadManager` we use.
/// Extracted so tests can inject fakes without touching gRPC or Keychain.
protocol MediaDownloading: Sendable {
    func download(
        messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL
}

extension MediaDownloadManager: MediaDownloading {}

/// The per-message directories of filename-preserving hard links that
/// `ChatMediaResolverImpl.decryptedURLWithDisplayName` hands to QuickLook.
///
/// A hard link is a second name for the same bytes. Deleting the cached
/// decrypted file alone — view-once, disappearing messages, "delete for me"
/// — left the plaintext fully readable under this directory until iOS got
/// around to purging tmp. Every path that removes a cached file must also
/// remove its links here, and sign-out and launch sweep the whole tree.
enum QuickLookDisplayLinks {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sanchr-quicklook", isDirectory: true)

    /// Removes the link directory for one message. No-op if there is none.
    static func remove(messageId: String, root: URL = root) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(messageId, isDirectory: true))
    }

    /// Removes every link. The links are recreated on demand, so this is
    /// safe whenever no preview is on screen: launch and sign-out.
    static func sweep(root: URL = root) {
        try? FileManager.default.removeItem(at: root)
    }
}

final class ChatMediaResolverImpl: ChatMediaResolving, @unchecked Sendable {
    private let download: MediaDownloading
    private let displayLinkRoot: URL

    init(
        download: MediaDownloading,
        displayLinkRoot: URL = QuickLookDisplayLinks.root
    ) {
        self.download = download
        self.displayLinkRoot = displayLinkRoot
        // Anything left from a previous run is plaintext for media that may
        // since have been deleted. The resolver is built once per launch.
        QuickLookDisplayLinks.sweep(root: displayLinkRoot)
        try? FileManager.default.createDirectory(
            at: displayLinkRoot,
            withIntermediateDirectories: true
        )
    }

    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        if let local = Self.localFileURL(for: attachment) {
            return local
        }
        return try await download.download(messageId: messageId, attachment: attachment)
    }

    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        let cached: URL
        if let local = Self.localFileURL(for: attachment) {
            cached = local
        } else {
            cached = try await download.download(
                messageId: messageId,
                attachment: attachment
            )
        }
        guard let displayName = attachment.filename, !displayName.isEmpty else {
            return cached
        }
        let perMessageDir = displayLinkRoot.appendingPathComponent(
            messageId,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: perMessageDir,
            withIntermediateDirectories: true
        )
        let linked = perMessageDir.appendingPathComponent(displayName)
        if FileManager.default.fileExists(atPath: linked.path) {
            return linked
        }
        try FileManager.default.linkItem(at: cached, to: linked)
        return linked
    }

    /// Returns the attachment's URL if it's already a readable local
    /// file on disk. Used for sender-side outgoing messages where the
    /// attachment.url is a `file://` path to the cached pre-upload copy
    /// — no decrypt pipeline needed.
    private static func localFileURL(for attachment: Message.MediaAttachment) -> URL? {
        guard attachment.url.isFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: attachment.url.path) else { return nil }
        return attachment.url
    }
}
