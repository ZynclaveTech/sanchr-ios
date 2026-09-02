import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// The session snapshot is a Keychain item. Updating the sync high-water
/// mark used to write it on every realtime message.
final class SessionSnapshotCoalescingTests: XCTestCase {

    private func makeService() async throws -> (SessionService, MockSecureStorage) {
        let storage = MockSecureStorage()
        let service = SessionService(
            secureStorage: storage,
            authRepository: MockAuthRepository(),
            privacySettings: PrivacySettingsCache(),
            snapshotPersistDelay: .milliseconds(150)
        )
        try await service.storeTokens(
            AuthTokens(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(3600),
                userId: "user-1",
                displayName: "User",
                phoneNumber: "+10000000000",
                avatarURL: "",
                deviceId: "1"
            )
        )
        return (service, storage)
    }

    func testABurstOfMessagesWritesTheSnapshotOnce() async throws {
        let (service, storage) = try await makeService()
        let before = storage.sessionSnapshotWrites

        for i in 1...50 {
            service.setLastMessageSyncTimestamp(Int64(i))
        }
        XCTAssertEqual(storage.sessionSnapshotWrites, before, "nothing is written synchronously")

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(storage.sessionSnapshotWrites, before + 1)
        XCTAssertEqual(storage.sessionSnapshot?.lastMessageSyncTimestamp, 50)
    }

    func testFlushWritesImmediately() async throws {
        let (service, storage) = try await makeService()
        let before = storage.sessionSnapshotWrites

        service.setLastMessageSyncTimestamp(7)
        service.flushPendingSnapshot()

        XCTAssertEqual(storage.sessionSnapshotWrites, before + 1)
        XCTAssertEqual(storage.sessionSnapshot?.lastMessageSyncTimestamp, 7)

        // The cancelled timer must not write a second time.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(storage.sessionSnapshotWrites, before + 1)
    }

    func testTheAppFlushesOnBackground() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("App/SanchrApp.swift"),
            encoding: .utf8
        )
        let background = try XCTUnwrap(app.range(of: "case .background:"))
        XCTAssertTrue(String(app[background.upperBound...].prefix(400)).contains("container.sessionService.flushPendingSnapshot()"))
    }
}
