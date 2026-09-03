import Foundation
import GRPC
import XCTest
@testable import Sanchr
@testable import SanchrShared

/// The session layer's concurrency contract: observed state mutates on the
/// main actor only, one refresh at a time, a rotated refresh token is picked
/// up between attempts, and credential changes reach the gRPC header cache.
@MainActor
final class SessionLayerConcurrencyTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Counts refresh calls, records the refresh token each received, and can
    /// delay so two callers overlap.
    private final class CountingAuthRepository: AuthRepositoryProtocol, @unchecked Sendable {
        let lock = NSLock()
        var refreshCalls = 0
        var receivedRefreshTokens: [String] = []
        var delay: Duration = .zero
        var results: [Result<AuthTokens, Error>] = []
        var onCall: (@Sendable (Int) -> Void)?

        func requestOTP(phoneNumber: String, displayName: String?) async throws -> OTPRequestResult {
            OTPRequestResult(requestId: phoneNumber, expiresInSeconds: 300, phoneNumber: phoneNumber)
        }
        func verifyOTP(phoneNumber: String, code: String, requestId: String, registrationLockPin: String?) async throws -> AuthTokens {
            throw AppError.unknown(underlying: "unused")
        }
        func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult {
            OTPRequestResult(requestId: phoneNumber, expiresInSeconds: 300, phoneNumber: phoneNumber)
        }
        func refreshToken(refreshToken: String) async throws -> AuthTokens {
            let index: Int = lock.withLock {
                refreshCalls += 1
                receivedRefreshTokens.append(refreshToken)
                return refreshCalls - 1
            }
            onCall?(index)
            try await Task.sleep(for: delay)
            let result = lock.withLock { results.indices.contains(index) ? results[index] : results.last! }
            return try result.get()
        }
        func logout(accessToken: String) async throws {}
        func deleteAccount() async throws {}
    }

    private func tokens(_ access: String, refresh: String = "") -> AuthTokens {
        AuthTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600),
                   userId: "user-1", displayName: "", phoneNumber: "", avatarURL: "", deviceId: "7")
    }

    private func authenticatedStorage() -> MockSecureStorage {
        let storage = MockSecureStorage()
        storage.accessToken = "old"
        storage.refreshToken = "refresh-1"
        storage.installationId = "install-1"
        storage.sessionSnapshot = SessionSnapshot(
            userId: "user-1", displayName: "Me", phoneNumber: "+15550000000", avatarURL: nil,
            tokenExpiresAt: Date().addingTimeInterval(-10), deviceId: "7", installationId: "install-1",
            lastMessageSyncTimestamp: 0)
        return storage
    }

    func testConcurrentForcedRefreshesShareOneNetworkCallAndTheSlotClears() async throws {
        let storage = authenticatedStorage()
        let repository = CountingAuthRepository()
        repository.delay = .milliseconds(150)
        repository.results = [.success(tokens("fresh-1")), .success(tokens("fresh-2"))]
        let service = SessionService(secureStorage: storage, authRepository: repository, privacySettings: PrivacySettingsCache())

        async let first = service.forceRefreshToken()
        async let second = service.forceRefreshToken()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, "fresh-1")
        XCTAssertEqual(b, "fresh-1", "the second caller joins the in-flight refresh")
        XCTAssertEqual(repository.refreshCalls, 1)

        // The finished task must not linger: a later refresh goes to the network again.
        let third = try await service.forceRefreshToken()
        XCTAssertEqual(third, "fresh-2")
        XCTAssertEqual(repository.refreshCalls, 2)
    }

    func testARotatedRefreshTokenIsUsedOnTheRetry() async throws {
        let storage = authenticatedStorage()
        let repository = CountingAuthRepository()
        // Attempt 1 fails with a transport error after the server rotated the
        // token (simulated by the storage changing under us); attempt 2 must
        // present the rotated token, not replay the consumed one.
        repository.results = [.failure(URLError(.networkConnectionLost)), .success(tokens("fresh"))]
        repository.onCall = { index in if index == 0 { storage.refreshToken = "refresh-2" } }
        let service = SessionService(secureStorage: storage, authRepository: repository, privacySettings: PrivacySettingsCache())

        _ = try await service.forceRefreshToken()
        XCTAssertEqual(repository.receivedRefreshTokens, ["refresh-1", "refresh-2"])
    }

    func testCredentialChangesInvalidateTheHeaderCache() async throws {
        let storage = authenticatedStorage()
        let repository = CountingAuthRepository()
        repository.results = [.success(tokens("fresh"))]
        let counter = NSLock(); nonisolated(unsafe) var invalidations = 0
        let service = SessionService(
            secureStorage: storage, authRepository: repository, privacySettings: PrivacySettingsCache(),
            onCredentialsChanged: { counter.withLock { invalidations += 1 } })

        _ = try await service.forceRefreshToken()
        XCTAssertEqual(counter.withLock { invalidations }, 1, "storeTokens")
        try await service.clearSession()
        XCTAssertEqual(counter.withLock { invalidations }, 2, "clearSession")
    }

    func testEveryMutatorIsMainActorIsolated() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Shared/Services/SessionService.swift"), encoding: .utf8)
        for name in ["func storeTokens(", "func forceRefreshToken(", "private func refreshToken(", "func updateProfile(",
                     "func setLastMessageSyncTimestamp(", "func clearSession(", "func deleteAccount(",
                     "private func clearSessionForReauth(", "func resetMessageSyncHighWaterMark("] {
            let range = try XCTUnwrap(source.range(of: name), name)
            let before = String(source[..<range.lowerBound].suffix(60))
            XCTAssertTrue(before.contains("@MainActor"), "\(name) must be @MainActor")
        }
        XCTAssertTrue(source.contains("activeRefreshTask = task"), "the slot is filled before any await")
    }

    // MARK: - Interceptor

    func testUnauthenticatedOnAnAuthFreePathDoesNotTriggerRefresh() {
        typealias Interceptor = AuthInterceptor<Sanchr_Auth_LoginRequest, Sanchr_Auth_AuthResponse>
        XCTAssertFalse(Interceptor.shouldTriggerRefresh(path: "/sanchr.auth.AuthService/VerifyOTP", code: .unauthenticated), "a wrong OTP")
        XCTAssertFalse(Interceptor.shouldTriggerRefresh(path: "/sanchr.auth.AuthService/RefreshToken", code: .unauthenticated), "a rejected refresh")
        XCTAssertTrue(Interceptor.shouldTriggerRefresh(path: "/sanchr.messaging.MessagingService/SendMessage", code: .unauthenticated))
        XCTAssertFalse(Interceptor.shouldTriggerRefresh(path: "/sanchr.messaging.MessagingService/SendMessage", code: .unavailable))
        XCTAssertFalse(Interceptor.needsAuth(path: "/sanchr.auth.AuthService/Login"))
        XCTAssertTrue(Interceptor.needsAuth(path: "/sanchr.keys.KeyService/GetPreKeyBundle"))
    }

    func testSealedSendCarriesNoDeviceIDButOtherPathsDo() {
        typealias Interceptor = AuthInterceptor<Sanchr_Auth_LoginRequest, Sanchr_Auth_AuthResponse>

        // The one path that must reach the server carrying nothing that
        // identifies the caller: no bearer token, no device id.
        XCTAssertFalse(Interceptor.attachesDeviceID(path: "/sanchr.messaging.MessagingService/SendSealedMessage"),
                        "a sealed envelope must not be labelled with the sending device")

        // The four auth paths withhold the bearer token but still need the
        // device id - registration depends on it.
        XCTAssertTrue(Interceptor.attachesDeviceID(path: "/sanchr.auth.AuthService/Register"))
        XCTAssertTrue(Interceptor.attachesDeviceID(path: "/sanchr.auth.AuthService/VerifyOTP"))
        XCTAssertTrue(Interceptor.attachesDeviceID(path: "/sanchr.auth.AuthService/Login"))
        XCTAssertTrue(Interceptor.attachesDeviceID(path: "/sanchr.auth.AuthService/RefreshToken"))

        // Ordinary authenticated paths are unaffected.
        XCTAssertTrue(Interceptor.attachesDeviceID(path: "/sanchr.messaging.MessagingService/SendMessage"))
        XCTAssertTrue(Interceptor.attachesDeviceID(path: "/sanchr.keys.KeyService/GetPreKeyBundle"))

        // needsAuth and shouldTriggerRefresh are related but distinct: the
        // sealed path withholds the bearer token and skips the refresh
        // trigger, independent of the device-id decision above.
        XCTAssertFalse(Interceptor.needsAuth(path: "/sanchr.messaging.MessagingService/SendSealedMessage"))
        XCTAssertFalse(Interceptor.shouldTriggerRefresh(path: "/sanchr.messaging.MessagingService/SendSealedMessage", code: .unauthenticated))
    }

    func testHeaderCacheReadsStorageOnceUntilInvalidated() {
        let reads = NSLock(); nonisolated(unsafe) var tokenReads = 0
        nonisolated(unsafe) var token: String? = "t1"
        let cache = AuthHeaderCache(
            readAccessToken: { reads.withLock { tokenReads += 1; return token } },
            readDeviceId: { "7" })
        XCTAssertEqual(cache.headers().accessToken, "t1")
        XCTAssertEqual(cache.headers().accessToken, "t1")
        XCTAssertEqual(reads.withLock { tokenReads }, 1, "served from memory")
        reads.withLock { token = "t2" }
        cache.invalidate()
        XCTAssertEqual(cache.headers().accessToken, "t2")
        XCTAssertEqual(reads.withLock { tokenReads }, 2)
    }

    func testHeaderCacheNeverPinsAMissingToken() {
        let reads = NSLock(); nonisolated(unsafe) var tokenReads = 0
        nonisolated(unsafe) var token: String? = nil
        let cache = AuthHeaderCache(
            readAccessToken: { reads.withLock { tokenReads += 1; return token } },
            readDeviceId: { nil })
        XCTAssertNil(cache.headers().accessToken)
        reads.withLock { token = "signed-in" }
        XCTAssertEqual(cache.headers().accessToken, "signed-in", "a nil token is re-read, no invalidation needed")
        XCTAssertEqual(reads.withLock { tokenReads }, 2)
    }

    // MARK: - Install marker

    func testFirstUpgradeSeedsTheMarkerInsteadOfPurging() {
        XCTAssertEqual(DependencyContainer.freshInstallAction(markerPresent: true, databaseExists: true), .nothing)
        XCTAssertEqual(DependencyContainer.freshInstallAction(markerPresent: true, databaseExists: false), .nothing)
        XCTAssertEqual(DependencyContainer.freshInstallAction(markerPresent: false, databaseExists: true), .seedMarkerOnly,
                       "an existing user's first launch of a build with the marker")
        XCTAssertEqual(DependencyContainer.freshInstallAction(markerPresent: false, databaseExists: false), .purge,
                       "a genuine reinstall over stale Keychain items")
    }
}
