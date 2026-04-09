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
