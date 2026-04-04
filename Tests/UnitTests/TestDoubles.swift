import Foundation
import LibSignalClient

@testable import Sanchr

final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private(set) var storage: [String: Data] = [:]

    func save(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func read(forKey key: String) throws -> Data? {
        storage[key]
    }

    func update(_ data: Data, forKey key: String) throws {
        storage[key] = data
    }

    func delete(forKey key: String) throws {
        storage.removeValue(forKey: key)
    }

    func deleteAll() throws {
        storage.removeAll()
    }
}

final class MockSecureStorage: SecureStorageProtocol, @unchecked Sendable {
    var accessToken: String?
    var refreshToken: String?
    var identityKey: Data?
    var preKeys: [Data] = []
    var deviceId: String?
    var installationId: String?
    var sessionSnapshot: SessionSnapshot?
    var databaseKey: String?

    private(set) var deleteAllTokensCallCount = 0
    private(set) var deleteSessionDataCallCount = 0
    private(set) var deleteAllKeysCallCount = 0

    func saveAccessToken(_ token: String) throws {
        accessToken = token
    }

    func readAccessToken() throws -> String? {
        accessToken
    }

    func saveRefreshToken(_ token: String) throws {
        refreshToken = token
    }

    func readRefreshToken() throws -> String? {
        refreshToken
    }

    func saveIdentityKey(_ key: Data) throws {
        identityKey = key
    }

    func readIdentityKey() throws -> Data? {
        identityKey
    }

    func savePreKeys(_ keys: [Data]) throws {
        preKeys = keys
    }

    func readPreKeys() throws -> [Data] {
        preKeys
    }

    func saveDeviceId(_ deviceId: String) throws {
        self.deviceId = deviceId
    }

    func readDeviceId() throws -> String? {
        deviceId
    }

    func saveInstallationId(_ installationId: String) throws {
        self.installationId = installationId
    }

    func readInstallationId() throws -> String? {
        installationId
    }

    func readOrCreateInstallationId() throws -> String {
        if let installationId, !installationId.isEmpty {
            return installationId
        }

        let generated = UUID().uuidString.lowercased()
        installationId = generated
        return generated
    }

    func saveSessionSnapshot(_ snapshot: SessionSnapshot) throws {
        sessionSnapshot = snapshot
    }

    func readSessionSnapshot() throws -> SessionSnapshot? {
        sessionSnapshot
    }

    func saveDatabaseKey(_ key: String) throws {
        databaseKey = key
    }

    func readDatabaseKey() throws -> String? {
        databaseKey
    }

    func readOrCreateDatabaseKey() throws -> String {
        if let databaseKey, !databaseKey.isEmpty {
            return databaseKey
        }

        let generated = UUID().uuidString
        databaseKey = generated
        return generated
    }

    func deleteAllTokens() throws {
        deleteAllTokensCallCount += 1
        accessToken = nil
        refreshToken = nil
    }

    func deleteSessionData() throws {
        deleteSessionDataCallCount += 1
        try deleteAllTokens()
        deviceId = nil
        installationId = nil
        sessionSnapshot = nil
        databaseKey = nil
    }

    func deleteAllKeys() throws {
        deleteAllKeysCallCount += 1
        identityKey = nil
        preKeys = []
    }
}

final class MockAuthRepository: AuthRepositoryProtocol, @unchecked Sendable {
    var refreshTokensResult: Result<AuthTokens, Error> = .failure(AppError.sessionExpired)
    private(set) var logoutAccessTokens: [String] = []

    func requestOTP(phoneNumber: String, displayName: String?) async throws -> OTPRequestResult {
        OTPRequestResult(requestId: phoneNumber, expiresInSeconds: 300, phoneNumber: phoneNumber)
    }

    func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws -> AuthTokens {
        throw AppError.unknown(underlying: "unused")
    }

    func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult {
        OTPRequestResult(requestId: phoneNumber, expiresInSeconds: 300, phoneNumber: phoneNumber)
    }

    func refreshToken(refreshToken: String) async throws -> AuthTokens {
        try refreshTokensResult.get()
    }

    func logout(accessToken: String) async throws {
        logoutAccessTokens.append(accessToken)
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {}

    func uploadPreKeyBundle(
        identityKey: Data,
        signedPreKey: Data,
        signedPreKeySignature: Data,
        oneTimePreKeys: [Data]
    ) async throws {}
}

final class MockMessageRepository: MessageRepositoryProtocol, @unchecked Sendable {
    var syncResult = MessageSyncResult(appliedCount: 0, latestTimestamp: 0)
    private(set) var syncedTimestamps: [Int64] = []
    private(set) var openStreamCallCount = 0
    private(set) var flushPendingAcksCallCount = 0
    var flushPendingAcksResult = 0
    private(set) var streamContinuation: AsyncStream<RealtimeEvent>.Continuation?

    func sendMessage(_ message: Message) async throws -> Message {
        message
    }

    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] {
        []
    }

    func fetchConversations() async throws -> [Conversation] {
        []
    }

    func markAsRead(conversationId: String, upToMessageId: String) async throws {}

    func deleteMessage(id: String, forEveryone: Bool) async throws {}

    func openMessageStream() async throws -> AsyncStream<RealtimeEvent> {
        openStreamCallCount += 1
        return AsyncStream { continuation in
            self.streamContinuation = continuation
        }
    }

    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws {}

    func fetchPreKeyBundle(userId: String) async throws -> Data {
        Data()
    }

    func syncPendingMessages(sinceTimestamp: Int64) async throws -> MessageSyncResult {
        syncedTimestamps.append(sinceTimestamp)
        return syncResult
    }

    func flushPendingAcks() async throws -> Int {
        flushPendingAcksCallCount += 1
        return flushPendingAcksResult
    }

    func emit(_ event: RealtimeEvent) {
        if case .message = event {
            flushPendingAcksCallCount += 1
        }
        streamContinuation?.yield(event)
    }

    func finishStream() {
        streamContinuation?.finish()
    }
}

final class MockKeyManager: KeyManagerProtocol, @unchecked Sendable {
    private(set) var replenishPreKeysCallCount = 0

    func generateIdentityIfNeeded() throws -> IdentityKeyPair {
        throw AppError.keyGenerationFailed
    }

    func generateSignedPreKey() throws -> SignedPreKeyRecord {
        throw AppError.keyGenerationFailed
    }

    func generateOneTimePreKeys(count: Int) throws -> [PreKeyRecord] {
        throw AppError.keyGenerationFailed
    }

    func uploadInitialKeyBundle() async throws {}

    func replenishPreKeys() async throws {
        replenishPreKeysCallCount += 1
    }

    func checkAndReplenishPreKeys(threshold: Int) async throws {}

    func fetchPreKeyBundle(userId: String, deviceId: Int32) async throws -> PreKeyBundle {
        throw AppError.keyGenerationFailed
    }

    func fetchUserDevices(recipientId: String) async throws -> [Int32] {
        []
    }

    var hasIdentityKeys: Bool { false }
}

final class MockCallEventRouter: CallEventRouting, @unchecked Sendable {
    private(set) var offers: [Vync_Messaging_CallOfferEvent] = []
    private(set) var lifecycleEvents: [Vync_Messaging_CallLifecycleEvent] = []
    private(set) var resetCallCount = 0

    func handleIncomingCallOffer(_ offer: Vync_Messaging_CallOfferEvent) {
        offers.append(offer)
    }

    func handleCallLifecycleEvent(_ event: Vync_Messaging_CallLifecycleEvent) {
        lifecycleEvents.append(event)
    }

    func resetState() {
        resetCallCount += 1
    }
}
