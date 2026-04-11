import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class BackupCoordinatorTests: XCTestCase {

    // MARK: - listBackups

    func test_listBackups_returnsSortedDescendingByDate() async throws {
        let service = MockBackupArchiveService()
        let older = Date().addingTimeInterval(-3600)  // 1 hour ago
        let newer = Date()
        // Service contract: listBackups() returns entries sorted descending by committedAt.
        // The coordinator is a pure pass-through; we seed the mock in the expected sort order.
        service.listBackupsResult = [
            BackupListEntry(id: "b2", committedAt: newer, byteSize: 2048, messageCount: 10),
            BackupListEntry(id: "b1", committedAt: older, byteSize: 1024, messageCount: 5),
        ]
        let coordinator = makeCoordinator(service: service)

        let entries = try await coordinator.listBackups()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, "b2")  // newer first (service-sorted)
        XCTAssertEqual(entries[1].id, "b1")
    }

    func test_listBackups_preservesMessageCount() async throws {
        let service = MockBackupArchiveService()
        service.listBackupsResult = [
            BackupListEntry(id: "b1", committedAt: Date(), byteSize: 512, messageCount: 42),
        ]
        let coordinator = makeCoordinator(service: service)

        let entries = try await coordinator.listBackups()

        XCTAssertEqual(entries.first?.messageCount, 42)
    }

    func test_listBackups_propagatesServiceError() async {
        let service = MockBackupArchiveService()
        service.listBackupsError = AppError.backupUnavailable
        let coordinator = makeCoordinator(service: service)

        do {
            _ = try await coordinator.listBackups()
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - restoreBackup(backupId:with:)

    func test_restoreBackup_callsServiceWithCorrectId() async {
        let service = MockBackupArchiveService()
        let keyManager = MockRecoveryKeyManager()
        keyManager.storedRecoveryKey = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
        keyManager.storedConfiguration = BackupConfiguration(
            isEnabled: true,
            lineageId: "lineage-1",
            formatVersion: 1,
            recoveryKeyConfirmedAt: Date()
        )
        let coordinator = makeCoordinator(service: service, keyManager: keyManager)

        await coordinator.restoreBackup(backupId: "backup-xyz", with: nil)

        XCTAssertEqual(service.capturedRestoreBackupId, "backup-xyz")
    }

    func test_restoreBackup_doesNotCallListBackups() async {
        let service = MockBackupArchiveService()
        let keyManager = MockRecoveryKeyManager()
        keyManager.storedRecoveryKey = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
        keyManager.storedConfiguration = BackupConfiguration(
            isEnabled: true,
            lineageId: "lineage-1",
            formatVersion: 1,
            recoveryKeyConfirmedAt: Date()
        )
        let coordinator = makeCoordinator(service: service, keyManager: keyManager)

        await coordinator.restoreBackup(backupId: "backup-xyz", with: nil)

        XCTAssertEqual(service.listBackupsCallCount, 0)
        XCTAssertNil(coordinator.errorMessage)
    }

    func test_restoreBackup_setsErrorOnFailure() async {
        let service = MockBackupArchiveService()
        service.restoreBackupError = AppError.backupIntegrityCheckFailed(reason: "bad hash")
        let keyManager = MockRecoveryKeyManager()
        keyManager.storedRecoveryKey = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
        let coordinator = makeCoordinator(service: service, keyManager: keyManager)

        await coordinator.restoreBackup(backupId: "backup-xyz", with: nil)

        XCTAssertNotNil(coordinator.errorMessage)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        service: MockBackupArchiveService = MockBackupArchiveService(),
        keyManager: MockRecoveryKeyManager = MockRecoveryKeyManager(),
        keyDeriver: MockBackupKeyDeriver = MockBackupKeyDeriver()
    ) -> BackupCoordinator {
        BackupCoordinator(
            backupService: service,
            recoveryKeyManager: keyManager,
            backupKeyDeriver: keyDeriver,
            currentUserIdProvider: { "user-1" },
            postRestore: {}
        )
    }
}
