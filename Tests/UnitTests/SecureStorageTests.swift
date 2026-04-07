import XCTest
import SanchrShared

@testable import Sanchr

final class SecureStorageTests: XCTestCase {
    func testInstallationAndDatabaseKeysAreStableAfterFirstCreation() throws {
        let storage = SecureStorage(keychain: MockKeychainService())

        let installationId = try storage.readOrCreateInstallationId()
        let secondInstallationId = try storage.readOrCreateInstallationId()
        XCTAssertEqual(secondInstallationId, installationId)

        let databaseKey = try storage.readOrCreateDatabaseKey()
        let secondDatabaseKey = try storage.readOrCreateDatabaseKey()
        XCTAssertEqual(secondDatabaseKey, databaseKey)

        let secretProvider = DeviceSecretProvider(secureStorage: storage)
        let masterSecret = try secretProvider.readOrCreateDeviceMasterSecret()
        let secondMasterSecret = try secretProvider.readOrCreateDeviceMasterSecret()
        XCTAssertEqual(masterSecret, secondMasterSecret)
        XCTAssertEqual(try secretProvider.localDatabasePassphrase(), try secretProvider.localDatabasePassphrase())
    }

    func testSessionSnapshotRoundTripsThroughKeychainStorage() throws {
        let storage = SecureStorage(keychain: MockKeychainService())
        let snapshot = SessionSnapshot(
            userId: "user-1",
            displayName: "Test User",
            phoneNumber: "+15551234567",
            avatarURL: "https://example.com/avatar.png",
            tokenExpiresAt: Date(timeIntervalSince1970: 1_750_000_000),
            deviceId: "7",
            installationId: "install-1",
            lastMessageSyncTimestamp: 42
        )

        try storage.saveSessionSnapshot(snapshot)

        XCTAssertEqual(try storage.readSessionSnapshot(), snapshot)
    }

    func testBackupConfigurationRoundTrips() throws {
        let storage = SecureStorage(keychain: MockKeychainService())
        let configuration = BackupConfiguration(
            isEnabled: true,
            lineageId: UUID().uuidString.lowercased(),
            formatVersion: 1,
            recoveryKeyConfirmedAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastBackupAt: Date(timeIntervalSince1970: 1_760_000_100),
            lastBackupContentHash: "abc123"
        )

        try storage.saveBackupConfiguration(configuration)
        try storage.saveRecoveryKey("abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234")

        XCTAssertEqual(try storage.readBackupConfiguration(), configuration)
        XCTAssertNotNil(try storage.readRecoveryKey())
    }
}
