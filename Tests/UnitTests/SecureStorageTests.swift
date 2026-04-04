import XCTest

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
}
