import Combine
import Foundation
import LibSignalClient
import SanchrShared

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
    var deviceMasterSecret: Data?
    var recoveryKey: String?
    var backupConfiguration: BackupConfiguration?
    var mediaAccessSecret: Data?

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

    func saveDeviceMasterSecret(_ secret: Data) throws {
        deviceMasterSecret = secret
    }

    func readDeviceMasterSecret() throws -> Data? {
        deviceMasterSecret
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

    func saveMediaAccessSecret(_ secret: Data) throws {
        mediaAccessSecret = secret
    }

    func readMediaAccessSecret() throws -> Data? {
        mediaAccessSecret
    }

    func saveRecoveryKey(_ key: String) throws {
        recoveryKey = key
    }

    func readRecoveryKey() throws -> String? {
        recoveryKey
    }

    func saveBackupConfiguration(_ configuration: BackupConfiguration) throws {
        backupConfiguration = configuration
    }

    func readBackupConfiguration() throws -> BackupConfiguration? {
        backupConfiguration
    }

    func deleteBackupConfiguration() throws {
        backupConfiguration = nil
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
    }

    func deleteAllKeys() throws {
        deleteAllKeysCallCount += 1
        identityKey = nil
        preKeys = []
    }

    func deleteDeviceSecrets() throws {
        deviceMasterSecret = nil
        databaseKey = nil
    }

    func deleteBackupMaterial() throws {
        recoveryKey = nil
        try deleteBackupConfiguration()
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

    var deleteAccountCallCount = 0
    var deleteAccountError: Error?
    func deleteAccount() async throws {
        deleteAccountCallCount += 1
        if let deleteAccountError { throw deleteAccountError }
    }

}

final class MockMessageRepository: MessageRepositoryProtocol, @unchecked Sendable {
    var syncResult = MessageSyncResult(appliedCount: 0, latestTimestamp: 0)
    private(set) var syncedTimestamps: [Int64] = []
    private(set) var openStreamCallCount = 0
    private(set) var flushPendingAcksCallCount = 0
    private(set) var closeStreamCallCount = 0
    private(set) var presenceHeartbeats: [Vync_Messaging_DevicePresenceState] = []
    var presenceSnapshot: [Vync_Messaging_PresenceUpdate] = []
    var flushPendingAcksResult = 0
    private(set) var streamContinuation: AsyncStream<RealtimeEvent>.Continuation?

    func sendMessage(_ message: Message) async throws -> Message {
        message
    }

    private(set) var deleteViewOnceCalls: [String] = []
    func deleteViewOnceMessage(messageId: String) async throws {
        deleteViewOnceCalls.append(messageId)
    }

    private(set) var sentSystemEvents: [(Message.SystemEvent, String)] = []
    func sendSystemEvent(_ event: Message.SystemEvent, conversationId: String) async throws {
        sentSystemEvents.append((event, conversationId))
    }

    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] {
        []
    }

    func fetchConversations() async throws -> [Conversation] {
        []
    }

    func markAsRead(conversationId: String, upToMessageId: String) async throws {}

    func markAsReadLocally(conversationId: String, upToMessageId: String) async throws {}

    func deleteMessage(id: String, forEveryone: Bool) async throws {}

    func openMessageStream() async throws -> AsyncStream<RealtimeEvent> {
        openStreamCallCount += 1
        return AsyncStream { continuation in
            self.streamContinuation = continuation
        }
    }

    func closeMessageStream() async {
        closeStreamCallCount += 1
        streamContinuation?.finish()
        streamContinuation = nil
    }

    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws {}

    func sendPresenceHeartbeat(
        deviceState: Vync_Messaging_DevicePresenceState,
        sentAtMs: Int64
    ) async throws {
        presenceHeartbeats.append(deviceState)
    }

    func fetchPreKeyBundle(userId: String) async throws -> Data {
        Data()
    }

    func fetchPresenceSnapshot(userIds: [String]) async throws -> [Vync_Messaging_PresenceUpdate] {
        presenceSnapshot.filter { userIds.contains($0.userID) }
    }

    func syncPendingMessages(sinceTimestamp: Int64) async throws -> MessageSyncResult {
        syncedTimestamps.append(sinceTimestamp)
        return syncResult
    }

    func flushPendingAcks() async throws -> Int {
        flushPendingAcksCallCount += 1
        return flushPendingAcksResult
    }

    var startDirectConversationResult: String = "conv-mock"
    private(set) var startDirectConversationCalls: [String] = []
    func startDirectConversation(peerUserId: String) async throws -> String {
        startDirectConversationCalls.append(peerUserId)
        return startDirectConversationResult
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

    func fetchPreKeyCount() async throws -> Int { 0 }
    func signedPreKeyCreatedAt() throws -> Date? { nil }

    private(set) var resetIdentityKeysCallCount = 0
    func resetIdentityKeys() async throws {
        resetIdentityKeysCallCount += 1
    }
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

// MARK: - Network

final class MockNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    var isConnected: Bool = true
    var connectionType: NetworkMonitor.ConnectionType = .wifi
    let subject = CurrentValueSubject<Bool, Never>(true)

    var connectivityPublisher: AnyPublisher<Bool, Never> {
        subject.eraseToAnyPublisher()
    }
}

// MARK: - MockBackupArchiveService

final class MockBackupArchiveService: BackupArchiveServiceProtocol, @unchecked Sendable {
    var performBackupResult: BackupUploadOutcome? = nil
    var performBackupError: Error? = nil
    var restoreLatestResult: BackupRestoreOutcome = BackupRestoreOutcome(
        lineageID: "test-lineage", formatVersion: 1, backupDate: nil, contentHash: nil
    )
    var restoreLatestError: Error? = nil
    var listBackupsResult: [BackupListEntry] = []
    var listBackupsError: Error? = nil
    var restoreBackupResult: BackupRestoreOutcome = BackupRestoreOutcome(
        lineageID: "test-lineage", formatVersion: 1, backupDate: nil, contentHash: nil
    )
    var restoreBackupError: Error? = nil
    var deleteRemoteBackupsError: Error? = nil

    // Capture arguments for assertion
    var capturedRestoreBackupId: String? = nil

    func performBackup(
        configuration: BackupConfiguration,
        material: DerivedBackupMaterial,
        currentUserId: String?,
        force: Bool
    ) async throws -> BackupUploadOutcome? {
        if let error = performBackupError { throw error }
        return performBackupResult
    }

    func restoreLatestBackup(
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome {
        if let error = restoreLatestError { throw error }
        return restoreLatestResult
    }

    func deleteRemoteBackups(lineageID: String?) async throws {
        if let error = deleteRemoteBackupsError { throw error }
    }

    func listBackups() async throws -> [BackupListEntry] {
        if let error = listBackupsError { throw error }
        return listBackupsResult
    }

    func restoreBackup(
        backupId: String,
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome {
        capturedRestoreBackupId = backupId
        if let error = restoreBackupError { throw error }
        return restoreBackupResult
    }
}

// MARK: - MockRecoveryKeyManager

final class MockRecoveryKeyManager: RecoveryKeyManagerProtocol, @unchecked Sendable {
    var storedConfiguration: BackupConfiguration? = nil
    var storedRecoveryKey: String? = nil
    var generateKeyResult: String = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
    var enableBackupsResult: BackupConfiguration = BackupConfiguration(
        isEnabled: true,
        lineageId: "test-lineage",
        formatVersion: 1,
        recoveryKeyConfirmedAt: Date()
    )

    func loadConfiguration() throws -> BackupConfiguration? { storedConfiguration }
    func readRecoveryKey() throws -> String? { storedRecoveryKey }
    func generateRecoveryKey() throws -> String { generateKeyResult }
    func enableBackups(with recoveryKey: String, lineageId: String) throws -> BackupConfiguration {
        storedRecoveryKey = recoveryKey
        storedConfiguration = enableBackupsResult
        return enableBackupsResult
    }
    func disableBackups() throws {
        storedConfiguration = nil
        storedRecoveryKey = nil
    }
    func updateBackupState(lastBackupAt: Date?, lastBackupContentHash: String?) throws {}
    func persistRestoredBackup(
        recoveryKey: String,
        lineageId: String,
        formatVersion: Int32,
        lastBackupAt: Date?,
        lastBackupContentHash: String?
    ) throws -> BackupConfiguration {
        storedRecoveryKey = recoveryKey
        return enableBackupsResult
    }
    func clearBackupMaterial() throws {
        storedRecoveryKey = nil
        storedConfiguration = nil
    }
}

// MARK: - MockBackupKeyDeriver

final class MockBackupKeyDeriver: BackupKeyDeriverProtocol, @unchecked Sendable {
    var derivedMaterial: DerivedBackupMaterial = DerivedBackupMaterial(
        metadataKey: Data(), aesKey: nil, hmacKey: nil, backupId: nil
    )
    var deriveError: Error? = nil

    func deriveMaterial(recoveryKey: String, userId: String?) throws -> DerivedBackupMaterial {
        if let error = deriveError { throw error }
        return derivedMaterial
    }
}
