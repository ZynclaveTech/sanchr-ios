import Foundation
import SanchrShared

/// Narrow, injectable surface of `MessageSender` used by the coordinator.
/// Lets tests substitute a spy without needing a full `MessageSender`
/// instance.
///
/// This protocol lives in the main-app (`Sanchr`) module, not
/// `SanchrShared`, because `VaultRepositoryProtocol` — the other
/// dependency the coordinator consumes — is a main-app type. Making
/// this protocol `public` would therefore be inconsistent with
/// `VaultRepositoryProtocol`'s internal access level and is also
/// rejected by Swift 6 (a `public` coordinator init cannot take an
/// internal parameter). Internal is the correct scope: every call site
/// lives inside the `Sanchr` target.
protocol VaultMessageSending: AnyObject, Sendable {
    func sendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MessageSendReceipt
}

extension MessageSender: VaultMessageSending {}

/// Protocol surface of `VaultSharingCoordinator` for dependency
/// injection. Production code uses the concrete actor; tests substitute
/// a stub.
protocol VaultSharingCoordinating: Sendable {
    func prepareForExternalShare(item: VaultItem) async throws -> URL
    func cleanupTempFile(at url: URL) async
    func shareToChat(item: VaultItem, conversationId: String) async throws -> VaultSharingCoordinator.ShareOutcome
    func reshareToCurrentChat(item: VaultItem, conversationId: String) async throws -> VaultSharingCoordinator.ShareOutcome
}

/// Workflow coordinator for vault save-and-share flows.
///
/// Owns the shared download → build-attachment-intent → send pipeline
/// used by:
///
/// - `VaultViewModel` Save button (download + write temp file +
///   `UIActivityViewController` or Photos/Files save)
/// - `VaultViewModel` Share button → "Share in chat" path
/// - `ChatDetailViewModel.send(intent: .vaultItem)` — the reverse
///   direction where the user picks a vault item from the chat
///   attachment picker
///
/// All three routes share a single internal primitive so the download,
/// temp-file lifecycle, and type-to-intent mapping stay DRY.
///
/// ## Temp file layout
///
/// Each share writes a file at:
///
///     NSTemporaryDirectory()/vault-share/<UUID>/<original-filename>
///
/// The UUID subdirectory prevents filename collisions if the user shares
/// two items named `"doc.pdf"` in quick succession. The original
/// filename is preserved because external share targets (AirDrop,
/// Messages, Mail) use the URL's last path component for their own
/// display.
///
/// ## Cleanup
///
/// - Successful external share: caller invokes `cleanupTempFile(at:)`
///   from `UIActivityViewController`'s completion handler.
/// - Successful chat share: coordinator cleans up in a `defer` after
///   `messageSender.sendMedia` returns (Task 5).
/// - Failed download: the UUID subdirectory is torn down before the
///   error is rethrown.
/// - App crash mid-share: `sweepOrphanedTempFiles()` runs on launch
///   from `DependencyContainer.init` and deletes the entire
///   `vault-share/` root. No valid share spans an app restart.
actor VaultSharingCoordinator: VaultSharingCoordinating {

    struct ShareOutcome: Sendable {
        let conversationId: String
        let bytesUploaded: Int64

        init(conversationId: String, bytesUploaded: Int64) {
            self.conversationId = conversationId
            self.bytesUploaded = bytesUploaded
        }
    }

    private let vaultRepository: VaultRepositoryProtocol
    private let messageSender: VaultMessageSending
    private let fileManager: FileManager

    init(
        vaultRepository: VaultRepositoryProtocol,
        messageSender: VaultMessageSending,
        fileManager: FileManager = .default
    ) {
        self.vaultRepository = vaultRepository
        self.messageSender = messageSender
        self.fileManager = fileManager
    }

    // MARK: - External share (Flow B2)

    /// Downloads a vault item, writes it to a temp file, and returns
    /// the URL. Caller owns the returned URL and MUST call
    /// `cleanupTempFile(at:)` when the share sheet closes — typically
    /// from `UIActivityViewController.completionWithItemsHandler`.
    func prepareForExternalShare(item: VaultItem) async throws -> URL {
        let data: Data
        do {
            data = try await vaultRepository.downloadItem(id: item.id)
        } catch {
            SanchrLogger.vault.error(
                "VaultSharingCoordinator.prepareForExternalShare: download failed for \(item.id.prefix(8)): \(error.localizedDescription)"
            )
            throw error
        }

        let tempURL: URL
        do {
            tempURL = try writeTempFile(data: data, filename: Self.safeFileName(for: item))
        } catch {
            SanchrLogger.vault.error(
                "VaultSharingCoordinator.prepareForExternalShare: temp write failed for \(item.id.prefix(8)): \(error.localizedDescription)"
            )
            throw error
        }

        SanchrLogger.vault.info(
            "VaultSharingCoordinator.prepareForExternalShare: wrote \(data.count) bytes for \(item.id.prefix(8)) at \(tempURL.lastPathComponent)"
        )
        return tempURL
    }

    /// Deletes a temp file AND its enclosing UUID subdirectory. Safe to
    /// call with a nonexistent path — logs a warning and returns.
    func cleanupTempFile(at url: URL) {
        let subdirectory = url.deletingLastPathComponent()
        do {
            if fileManager.fileExists(atPath: subdirectory.path) {
                try fileManager.removeItem(at: subdirectory)
                SanchrLogger.vault.info(
                    "VaultSharingCoordinator.cleanupTempFile: removed \(subdirectory.lastPathComponent)"
                )
            }
        } catch {
            SanchrLogger.vault.warning(
                "VaultSharingCoordinator.cleanupTempFile: failed to remove \(subdirectory.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Share to chat (Task 5 stubs)

    /// Task 5 implements the real body. Task 1 tests never call this
    /// method, and the view model doesn't call it until after Task 5
    /// lands the implementation.
    func shareToChat(
        item: VaultItem,
        conversationId: String
    ) async throws -> ShareOutcome {
        fatalError("VaultSharingCoordinator.shareToChat: Task 5 implements this")
    }

    func reshareToCurrentChat(
        item: VaultItem,
        conversationId: String
    ) async throws -> ShareOutcome {
        fatalError("VaultSharingCoordinator.reshareToCurrentChat: Task 5 implements this")
    }

    // MARK: - Orphan sweep

    /// One-shot sweep that removes the entire `vault-share/` directory
    /// and everything under it. Called from `DependencyContainer.init`
    /// at app launch to clean up temp files from a crashed share.
    ///
    /// This is `nonisolated static` so it can run during app startup
    /// before the coordinator instance exists.
    nonisolated static func sweepOrphanedTempFiles(
        fileManager: FileManager = .default
    ) async {
        let root = Self.shareRoot()
        guard fileManager.fileExists(atPath: root.path) else { return }
        do {
            try fileManager.removeItem(at: root)
            SanchrLogger.vault.info(
                "VaultSharingCoordinator.sweepOrphanedTempFiles: cleared \(root.path)"
            )
        } catch {
            SanchrLogger.vault.warning(
                "VaultSharingCoordinator.sweepOrphanedTempFiles: sweep failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Private helpers

    private nonisolated static func shareRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-share", isDirectory: true)
    }

    /// Returns a filename that's safe to use as a filesystem last-path
    /// component. Strips path separators and null bytes, and replaces
    /// empty names with "untitled".
    private static func safeFileName(for item: VaultItem) -> String {
        let raw = item.name.isEmpty ? "untitled" : item.name
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned
    }

    /// Creates a new UUID subdirectory under the vault-share root and
    /// writes `data` to a file named `filename` inside it. Returns the
    /// URL of the written file. On any failure, attempts to tear down
    /// the subdirectory before rethrowing.
    private func writeTempFile(data: Data, filename: String) throws -> URL {
        let subdirectory = Self.shareRoot()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(
            at: subdirectory,
            withIntermediateDirectories: true
        )

        let fileURL = subdirectory.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Tear down the subdirectory we just created so the failure
            // doesn't leak temp files.
            try? fileManager.removeItem(at: subdirectory)
            throw error
        }
        return fileURL
    }
}
