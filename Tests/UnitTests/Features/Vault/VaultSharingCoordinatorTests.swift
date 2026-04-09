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
/// Task 5 replaces this with a real `SpyMessageSender` when
/// `shareToChat` lands.
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
