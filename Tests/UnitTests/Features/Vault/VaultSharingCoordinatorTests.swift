import XCTest
@testable import Sanchr
import SanchrShared

@MainActor
final class VaultSharingCoordinatorTests: XCTestCase {

    // MARK: - prepareForExternalShare

    func test_prepareForExternalShare_writesReadableTempFile() async throws {
        let vaultRepo = SpyVaultRepository()
        let messageSender = UnusedMessageSender()
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: messageSender
        )

        let expectedBytes = Data("hello world".utf8)
        vaultRepo.downloadResult = .success(expectedBytes)

        let item = Self.makeVaultItem(
            id: "item-1",
            name: "greeting.txt",
            type: .document,
            sizeBytes: Int64(expectedBytes.count)
        )

        let tempURL = try await coordinator.prepareForExternalShare(item: item)
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        XCTAssertEqual(vaultRepo.downloadedIds, ["item-1"])

        let onDisk = try Data(contentsOf: tempURL)
        XCTAssertEqual(onDisk, expectedBytes)

        XCTAssertEqual(
            tempURL.lastPathComponent, "greeting.txt",
            "temp file must preserve original filename"
        )
        XCTAssertEqual(
            tempURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "vault-share",
            "temp file must live under vault-share/<UUID>/"
        )
    }

    func test_prepareForExternalShare_downloadFailure_surfacesError_noTempLeak() async {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .failure(
            AppError.decryptionFailed(reason: "no key")
        )
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: UnusedMessageSender()
        )
        let item = Self.makeVaultItem(id: "x", name: "x.pdf", type: .document, sizeBytes: 1)

        // Snapshot the share-root contents BEFORE the failed attempt so
        // we can assert the failure didn't add anything.
        let shareRoot = Self.shareRoot()
        let beforeCount = Self.subdirectoryCount(at: shareRoot)

        do {
            _ = try await coordinator.prepareForExternalShare(item: item)
            XCTFail("expected throw")
        } catch {
            // Expected
        }

        let afterCount = Self.subdirectoryCount(at: shareRoot)
        XCTAssertEqual(
            afterCount, beforeCount,
            "failed share must not leave temp files"
        )
    }

    // MARK: - cleanupTempFile

    func test_cleanupTempFile_deletesSubdirectory() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("x".utf8))
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: UnusedMessageSender()
        )
        let item = Self.makeVaultItem(id: "c", name: "c.txt", type: .document, sizeBytes: 1)

        let tempURL = try await coordinator.prepareForExternalShare(item: item)
        let subdirectory = tempURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        await coordinator.cleanupTempFile(at: tempURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: subdirectory.path),
            "cleanupTempFile must delete the UUID subdirectory"
        )
    }

    func test_cleanupTempFile_isSafeOnNonexistentPath() async {
        let coordinator = VaultSharingCoordinator(
            vaultRepository: SpyVaultRepository(),
            messageSender: UnusedMessageSender()
        )
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist/\(UUID())/nothing")
        await coordinator.cleanupTempFile(at: bogus)  // must not throw or crash
    }

    // MARK: - sweepOrphanedTempFiles

    func test_sweepOrphanedTempFiles_removesEntireShareRoot() async throws {
        // Seed a file under the share root, then call the sweep. The whole
        // directory must be gone.
        let shareRoot = Self.shareRoot()
        try FileManager.default.createDirectory(
            at: shareRoot,
            withIntermediateDirectories: true
        )
        let orphan = shareRoot.appendingPathComponent("leftover.bin")
        try Data("orphan".utf8).write(to: orphan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        await VaultSharingCoordinator.sweepOrphanedTempFiles()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: shareRoot.path),
            "sweep must remove the entire vault-share/ directory"
        )
    }

    // MARK: - safeFileName security + sanitization

    func test_safeFileName_emptyName_returnsUntitled() {
        let item = Self.makeVaultItem(id: "e", name: "", type: .document, sizeBytes: 1)
        XCTAssertEqual(VaultSharingCoordinator.safeFileName(for: item), "untitled")
    }

    func test_safeFileName_pathTraversalName_returnsUntitled() {
        let dotDot = Self.makeVaultItem(id: "d", name: "..", type: .document, sizeBytes: 1)
        XCTAssertEqual(VaultSharingCoordinator.safeFileName(for: dotDot), "untitled")

        let dot = Self.makeVaultItem(id: "d2", name: ".", type: .document, sizeBytes: 1)
        XCTAssertEqual(VaultSharingCoordinator.safeFileName(for: dot), "untitled")
    }

    func test_safeFileName_stripsBackslashAndSlash() {
        let item = Self.makeVaultItem(
            id: "b",
            name: "foo\\bar/baz.pdf",
            type: .document,
            sizeBytes: 1
        )
        XCTAssertEqual(
            VaultSharingCoordinator.safeFileName(for: item),
            "foo-bar-baz.pdf"
        )
    }

    func test_safeFileName_stripsControlCharacters() {
        let item = Self.makeVaultItem(
            id: "c",
            name: "foo\tbar\nbaz\u{7F}.txt",
            type: .document,
            sizeBytes: 1
        )
        XCTAssertEqual(
            VaultSharingCoordinator.safeFileName(for: item),
            "foo-bar-baz-.txt"
        )
    }

    func test_safeFileName_stripsLeadingDots() {
        let item = Self.makeVaultItem(
            id: "l",
            name: "...DS_Store",
            type: .document,
            sizeBytes: 1
        )
        XCTAssertEqual(
            VaultSharingCoordinator.safeFileName(for: item),
            "DS_Store"
        )
    }

    func test_safeFileName_truncatesOversizedName_preservingExtension() {
        // 500 bytes of 'a' + ".pdf" = 504 total. After truncation, should
        // be 200 bytes total, ending in ".pdf".
        let longBase = String(repeating: "a", count: 500)
        let item = Self.makeVaultItem(
            id: "t",
            name: "\(longBase).pdf",
            type: .document,
            sizeBytes: 1
        )
        let result = VaultSharingCoordinator.safeFileName(for: item)
        XCTAssertLessThanOrEqual(result.utf8.count, 200)
        XCTAssertTrue(result.hasSuffix(".pdf"), "extension must be preserved")
    }

    // MARK: - prepareForExternalShare failure paths

    func test_prepareForExternalShare_traversalName_containedInSubdirectory() async throws {
        // Defense in depth: `safeFileName` strips separators so the
        // sanitized name becomes a single path component that cannot
        // escape the UUID subdirectory. Verify that the resolved
        // absolute path is strictly rooted under vault-share/.
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("pwn".utf8))
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: UnusedMessageSender()
        )
        let item = Self.makeVaultItem(
            id: "e",
            name: "../../evil.pdf",
            type: .document,
            sizeBytes: 3
        )

        let tempURL = try await coordinator.prepareForExternalShare(item: item)
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        // The sanitized filename must not contain any unescaped path
        // separators — a `/` or `\` in the last-path-component would
        // mean `appendingPathComponent` split it into a nested path.
        let lastComponent = tempURL.lastPathComponent
        XCTAssertFalse(
            lastComponent.contains("/"),
            "sanitized filename must not contain '/': got \(lastComponent)"
        )
        XCTAssertFalse(
            lastComponent.contains("\\"),
            "sanitized filename must not contain '\\': got \(lastComponent)"
        )

        // Strict containment: the standardized absolute path must start
        // with the standardized vault-share root path. This is the real
        // security invariant — even if the sanitized filename contained
        // `..` substrings, there's no `/` to act as a path separator so
        // the filesystem treats it as a single component.
        let standardizedPath = tempURL.standardizedFileURL.path
        let shareRootPath = Self.shareRoot().standardizedFileURL.path
        XCTAssertTrue(
            standardizedPath.hasPrefix(shareRootPath + "/"),
            "temp file must remain under \(shareRootPath): \(standardizedPath)"
        )
    }

    func test_prepareForExternalShare_emptyName_writesUntitledFile() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("x".utf8))
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: UnusedMessageSender()
        )
        let item = Self.makeVaultItem(id: "empty", name: "", type: .document, sizeBytes: 1)

        let tempURL = try await coordinator.prepareForExternalShare(item: item)
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        XCTAssertEqual(tempURL.lastPathComponent, "untitled")
    }

    // MARK: - shareToChat (Flow B1)

    func test_shareToChat_photoItem_buildsPhotoAttachmentAndCallsSendMedia() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("photo-bytes".utf8))
        let sender = SpyMessageSender()
        sender.sendResult = .success(
            MessageSendReceipt(
                chatId: "conv-1",
                messageId: "msg-1",
                serverTimestampMs: 1_712_700_000_000
            )
        )
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: sender
        )
        let photo = Self.makeVaultItem(
            id: "p1",
            name: "photo.jpg",
            type: .photo,
            sizeBytes: 11
        )

        let outcome = try await coordinator.shareToChat(
            item: photo,
            conversationId: "conv-1"
        )

        XCTAssertEqual(outcome.conversationId, "conv-1")
        XCTAssertEqual(outcome.bytesUploaded, 11)
        XCTAssertEqual(sender.sendCalls.count, 1)
        let call = try XCTUnwrap(sender.sendCalls.first)
        XCTAssertEqual(call.chatId, "conv-1")
        XCTAssertEqual(call.attachment.mimeType, "image/jpeg")
        XCTAssertEqual(call.attachment.filename, "photo.jpg")
        XCTAssertEqual(call.attachment.sizeBytes, 11)
        XCTAssertNil(call.caption)

        // Temp file is cleaned up on success.
        let shareRoot = Self.shareRoot()
        if FileManager.default.fileExists(atPath: shareRoot.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: shareRoot, includingPropertiesForKeys: nil
            )) ?? []
            XCTAssertEqual(
                contents.count, 0,
                "successful share must clean up its UUID subdirectory"
            )
        }
    }

    func test_shareToChat_documentItem_buildsFileAttachmentWithPDFMime() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("pdf-bytes".utf8))
        let sender = SpyMessageSender()
        sender.sendResult = .success(
            MessageSendReceipt(
                chatId: "conv-2",
                messageId: "msg-2",
                serverTimestampMs: 1_712_700_000_000
            )
        )
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: sender
        )
        let doc = Self.makeVaultItem(
            id: "d1",
            name: "report.pdf",
            type: .document,
            sizeBytes: 9
        )

        _ = try await coordinator.shareToChat(item: doc, conversationId: "conv-2")

        let call = try XCTUnwrap(sender.sendCalls.first)
        XCTAssertEqual(call.attachment.mimeType, "application/pdf")
        XCTAssertEqual(call.attachment.filename, "report.pdf")
    }

    func test_shareToChat_sendFailure_cleansTempDir_leavesVaultUntouched() async {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("x".utf8))
        let sender = SpyMessageSender()
        sender.sendResult = .failure(
            AppError.grpcError(code: 13, message: "gRPC broke")
        )
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: sender
        )
        let item = Self.makeVaultItem(id: "f", name: "f.jpg", type: .photo, sizeBytes: 1)

        do {
            _ = try await coordinator.shareToChat(item: item, conversationId: "c")
            XCTFail("expected throw")
        } catch {
            // Expected
        }

        XCTAssertEqual(vaultRepo.downloadedIds, ["f"])
        // Verify the vault-share directory has no leftover UUID subdirs.
        let shareRoot = Self.shareRoot()
        if FileManager.default.fileExists(atPath: shareRoot.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: shareRoot, includingPropertiesForKeys: nil
            )) ?? []
            XCTAssertEqual(
                contents.count, 0,
                "failed share must clean up its UUID subdirectory"
            )
        }
    }

    func test_reshareToCurrentChat_delegatesToSameSendPipeline() async throws {
        let vaultRepo = SpyVaultRepository()
        vaultRepo.downloadResult = .success(Data("x".utf8))
        let sender = SpyMessageSender()
        sender.sendResult = .success(
            MessageSendReceipt(chatId: "c", messageId: "m", serverTimestampMs: 0)
        )
        let coordinator = VaultSharingCoordinator(
            vaultRepository: vaultRepo,
            messageSender: sender
        )
        let item = Self.makeVaultItem(id: "r", name: "r.pdf", type: .document, sizeBytes: 1)

        let outcome = try await coordinator.reshareToCurrentChat(
            item: item,
            conversationId: "c"
        )

        XCTAssertEqual(outcome.conversationId, "c")
        XCTAssertEqual(sender.sendCalls.count, 1)
    }

    // MARK: - Helpers

    private static func shareRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-share", isDirectory: true)
    }

    private static func subdirectoryCount(at url: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).count) ?? 0
    }

    private static func makeVaultItem(
        id: String,
        name: String,
        type: VaultItem.VaultItemType,
        sizeBytes: Int64
    ) -> VaultItem {
        VaultItem(
            id: id,
            mediaId: "media-\(id)",
            name: name,
            type: type,
            sizeBytes: sizeBytes,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

// MARK: - Test doubles

final class SpyVaultRepository: VaultRepositoryProtocol, @unchecked Sendable {
    enum DownloadResult {
        case success(Data)
        case failure(Error)
    }

    var downloadResult: DownloadResult = .success(Data())
    private(set) var downloadedIds: [String] = []

    func fetchItems() async throws -> [VaultItem] { [] }

    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws -> VaultItem {
        fatalError("not exercised")
    }

    func downloadItem(id: String) async throws -> Data {
        downloadedIds.append(id)
        switch downloadResult {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    func deleteItem(id: String) async throws {
        fatalError("not exercised")
    }

    func storageUsed() async throws -> Int64 { 0 }
}

/// Surrogate `VaultMessageSending` implementation used in Task 1 tests
/// where the coordinator's share-to-chat path is not exercised. Any
/// call to `sendMedia` is a bug — fatalError guards against that.
/// Task 5 adds `SpyMessageSender` alongside this for tests that DO
/// exercise the share-to-chat path; this surrogate stays in place so
/// pre-existing Task 1 tests continue to catch accidental sendMedia
/// calls.
final class UnusedMessageSender: VaultMessageSending, @unchecked Sendable {
    func sendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MessageSendReceipt {
        fatalError("UnusedMessageSender.sendMedia called in Task 1 tests")
    }
}

// MARK: - SpyMessageSender

/// Recording test double for `VaultMessageSending` used by the Task 5
/// share-to-chat tests. Each call to `sendMedia` is appended to
/// `sendCalls`, and the configured `sendResult` decides whether the
/// call succeeds with a `MessageSendReceipt` or throws.
///
/// Thread safety: no lock around `sendCalls` because all callers run
/// on `@MainActor` and calls are serialized through the coordinator
/// actor. This matches how `SpyPhotosSaver` in
/// `VaultViewModelShareTests.swift` is written.
final class SpyMessageSender: VaultMessageSending, @unchecked Sendable {
    struct Call: Sendable {
        let attachment: Message.MediaAttachment
        let caption: String?
        let chatId: String
    }

    enum SendResult {
        case success(MessageSendReceipt)
        case failure(Error)
    }

    var sendResult: SendResult = .success(
        MessageSendReceipt(chatId: "", messageId: "", serverTimestampMs: 0)
    )
    private(set) var sendCalls: [Call] = []

    func sendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MessageSendReceipt {
        sendCalls.append(Call(attachment: attachment, caption: caption, chatId: chatId))
        switch sendResult {
        case .success(let receipt):
            progress(1.0)
            return receipt
        case .failure(let error):
            throw error
        }
    }
}
