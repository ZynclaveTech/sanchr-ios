import SanchrShared
import XCTest
@testable import Sanchr

/// Phase 5 of the readiness plan: the cold-launch gate honours either lock
/// flag, the foreground lock offers the passcode after a biometry lockout,
/// account deletion empties the Keychain, and a broken database shows
/// recovery before anything else. There is deliberately no sign-out: like
/// WhatsApp, leaving means deleting the account.
@MainActor
final class LockAndWipeTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    override func tearDown() {
        let defaults = AppGroup.userDefaults
        defaults.removeObject(forKey: AppLockDefaultsKeys.screenLockEnabled)
        defaults.removeObject(forKey: AppLockDefaultsKeys.biometricLockEnabled)
        super.tearDown()
    }

    func testEitherLockFlagConfiguresTheLock() {
        let manager = AppLockManager()
        manager.screenLockEnabled = false
        manager.biometricLockEnabled = false
        XCTAssertFalse(manager.isLockConfigured)
        manager.screenLockEnabled = true
        XCTAssertTrue(manager.isLockConfigured, "a timeout without Face ID is still a lock")
        manager.screenLockEnabled = false
        manager.biometricLockEnabled = true
        XCTAssertTrue(manager.isLockConfigured)
        XCTAssertEqual(manager.isLockConfigured, AppLockDefaultsKeys.isLockEnabled, "app and share extension agree")
    }

    func testTheColdLaunchGateUsesTheSameDefinitionAsTheExtension() throws {
        let app = try source("App/SanchrApp.swift")
        let gate = try XCTUnwrap(app.range(of: "private var needsGate: Bool {"))
        let body = String(app[gate.upperBound...].prefix(120))
        XCTAssertTrue(body.contains("container.appLockManager.isLockConfigured && !hasAuthenticatedAtGate"))
        XCTAssertFalse(body.contains("biometricLockEnabled"))
    }

    func testForegroundLockOffersThePasscodeLikeTheGate() throws {
        let manager = try source("Shared/Services/AppLockManager.swift")
        XCTAssertFalse(manager.contains(".deviceOwnerAuthenticationWithBiometrics"),
                       "biometrics-only left a locked-out user with no way to type the passcode")
        let code = manager.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertEqual(code.components(separatedBy: ".deviceOwnerAuthentication").count - 1, 2, "canEvaluate + evaluate")
        XCTAssertTrue(manager.contains("localizedFallbackTitle = \"Use Passcode\""))
        XCTAssertFalse(manager.contains("authenticateWithPasscode"), "one path, not two that disagree")
    }

    func testDeletingTheAccountPurgesEveryKeychainItem() async throws {
        let storage = MockSecureStorage()
        storage.accessToken = "a"; storage.refreshToken = "r"; storage.installationId = "i"
        storage.sessionSnapshot = SessionSnapshot(
            userId: "u", displayName: "Me", phoneNumber: "+15550000000", avatarURL: nil,
            tokenExpiresAt: Date().addingTimeInterval(3600), deviceId: "1", installationId: "i",
            lastMessageSyncTimestamp: 0)
        let repository = MockAuthRepository()
        let service = SessionService(secureStorage: storage, authRepository: repository, privacySettings: PrivacySettingsCache())

        try await service.deleteAccount()
        XCTAssertEqual(repository.deleteAccountCallCount, 1)
        XCTAssertEqual(storage.purgeAllKeychainItemsCallCount, 1, "not just the session data")
        XCTAssertFalse(service.isAuthenticated)
    }

    func testDeepWipeAlsoClearsStandardDefaultsAndTheProfileKey() throws {
        let container = try source("App/DependencyContainer.swift")
        let wipe = try XCTUnwrap(container.range(of: "private func wipeAppGroupArtifacts() async {"))
        let body = String(container[wipe.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("UserDefaults.standard.removePersistentDomain(forName: bundleId)"))
        XCTAssertTrue(body.contains("try? profileKeyStore.deleteOwnProfileKey()"))
    }

    func testRecoveryScreenComesBeforeTheAuthenticatedApp() throws {
        let app = try source("App/SanchrApp.swift")
        let recovery = try XCTUnwrap(app.range(of: "if let localDataIssue = container.localDataIssue {"))
        let authenticated = try XCTUnwrap(app.range(of: "} else if container.sessionService.isAuthenticated && sessionReady {"))
        XCTAssertLessThan(recovery.lowerBound, authenticated.lowerBound,
                          "a signed-in user with an unopenable database must see recovery, not tabs over nothing")
    }
}
