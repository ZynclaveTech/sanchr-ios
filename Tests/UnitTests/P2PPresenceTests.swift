// Tests/UnitTests/P2PPresenceTests.swift
import XCTest
import GRPC
import NIOCore
import NIOEmbedded
import SanchrShared
@testable import Sanchr

// MARK: - Stubs specific to P2P presence tests

/// Records the `contentType` and `conversationId` passed to `encodeInnerPayload`
/// so tests can assert on the sealed envelope shape.
private final class CapturingSealedSenderManager: SealedSenderManagerProtocol, @unchecked Sendable {
    var capturedContentType: String?
    var capturedConversationId: String?
    var capturedContent: Data?
    var capturedMessageId: String?

    func acquireDeliveryToken() async throws -> Data { Data("tok".utf8) }
    func getSenderCertificate() async throws -> Data { Data() }
    func encodeInnerPayload(
        conversationId: String,
        messageId: String?,
        contentType: String,
        content: Data,
        isSync: Bool,
        expiresAfterSecs: Int64?,
        replyToMessageId: String?
    ) throws -> Data {
        capturedContentType = contentType
        capturedConversationId = conversationId
        capturedMessageId = messageId
        capturedContent = content
        return content
    }
    func decodeInnerPayload(_ data: Data) throws -> InnerPayload {
        InnerPayload(conversationId: "", contentType: "presence/v1", content: data, isSync: false)
    }
    static func isInnerPayload(_ data: Data) -> Bool { false }
    func replenishIfNeeded() async {}
}

/// Minimal SignalProtocol stub for the P2P send path.
private final class MinimalSignalProtocol: SignalProtocolManagerProtocol, @unchecked Sendable {
    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws
        -> [Sanchr_Messaging_DeviceMessage]
    {
        var dm = Sanchr_Messaging_DeviceMessage()
        dm.recipientID = recipientId
        dm.deviceID = 1
        dm.ciphertext = Data("fake-ct".utf8)
        return [dm]
    }

    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data { plaintext }
    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data { ciphertext }
    func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { Data() }
    func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
        throw AppError.decryptionFailed(reason: "not used in this test")
    }
    func encryptCallOffers(plaintext: Data, recipientId: String) async throws -> [Sanchr_Calling_DeviceCallOffer] { [] }
    func establishSession(with userId: String, deviceId: Int32) async throws {}
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
    func hasSession(with userId: String) -> Bool { true }
    func resetSession(with userId: String, deviceId: Int32) throws {}
    func resetSessions(with userId: String) async {}
    func relocateSession(
        fromUserId: String, fromDeviceId: Int32, toUserId: String, toDeviceId: Int32
    ) {}
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
    func markIdentityVerified(userId: String) {}
    func isIdentityVerified(userId: String) -> Bool { false }
    func identityVerifiedAt(userId: String) -> Date? { nil }
    func unmarkIdentityVerified(userId: String) {}
    func hasPendingIdentityChange(userId: String) -> Bool { false }
    func acceptIdentityChange(userId: String) {}
    func localIdentityKeyData() throws -> Data { Data() }
    func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
    var localUserId: String { "" }
}

/// Minimal local database stub (only `updateUserPresence` is used in these tests).
private final class PresenceLocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    var presenceUpdates: [(userId: String, status: User.Status)] = []

    func updateUserPresence(userId: String, status: User.Status, lastSeen: Date?) async throws {
        presenceUpdates.append((userId: userId, status: status))
    }

    func saveDraft(conversationId: String, text: String?) async throws { fatalError() }
    func draft(conversationId: String) async throws -> String? { fatalError() }
    func saveMessage(_ message: Message) async throws {}
    func fetchConversation(id: String) async throws -> Conversation? { nil }
    func saveIncomingMessageAndQueueAck(_ message: Message) async throws {}
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { [] }
    func deleteMessage(id: String) async throws {}
    func purgeExpiredMessages() async throws -> [String] { [] }
    func deleteAllMessages(conversationId: String) async throws -> [String] { [] }
    func disappearingDuration(conversationId: String) async throws -> Int64 { 0 }
    func setDisappearingDuration(conversationId: String, seconds: Int64) async throws {}
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws {}
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws {}
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { [] }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws {}
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { [] }
    func saveConversation(_ conversation: Conversation) async throws {}
    func fetchConversations() async throws -> [Conversation] { [] }
    func deleteConversation(id: String) async throws {}
    func saveContact(_ user: User) async throws {}
    func fetchContacts() async throws -> [User] { [] }
    func searchContacts(query: String) async throws -> [User] { [] }
    func saveVaultItem(_ item: VaultItem) async throws {}
    func fetchVaultItems() async throws -> [VaultItem] { [] }
    func fetchAllVaultItems() async throws -> [VaultItem] { [] }
    func deleteVaultItem(id: String) async throws {}
    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws {}
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { nil }
    func updateAccessKeyEntryLastAccessed(mediaId: String, lastAccessedAt: Date) async throws {}
    func deleteAccessKeyEntry(mediaId: String) async throws {}
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { 0 }
    func deleteAllAccessKeyEntries() async throws {}
    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { nil }
    func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws {}
    func clearAppearanceOverride(conversationId: String) async throws {}
    func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? { nil }
    func setVaultPolicy(_ policy: ChatVaultPolicy) async throws {}
    func clearVaultPolicy(conversationId: String) async throws {}
    func fetchMessageById(_ messageId: String) async throws -> Message? { nil }
    func hasLocalHistory() async throws -> Bool { false }
    func exportBackupSnapshot(currentUserId: String?, fingerprint: String) async throws -> BackupArchiveSnapshot {
        fatalError("PresenceLocalDatabase: exportBackupSnapshot must not be called")
    }
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?, localFingerprint: String) async throws {
        fatalError("PresenceLocalDatabase: restoreBackupSnapshot must not be called")
    }
    func purgeAllData() async throws {}
    func updateConversationLastMessageStatusIfMatches(
        conversationId: String, messageId: String, status: Message.DeliveryStatus
    ) async throws {}
}

/// Minimal GRPC client stub for P2P presence tests.
private final class PresenceGRPCClient: GRPCClientProtocol, @unchecked Sendable {
    let messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol
    init(messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol) {
        self.messagingService = messagingService
    }
    func connect() async throws {}
    func disconnect() async throws {}
    var isConnected: Bool { false }
    var authService: Sanchr_Auth_AuthServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: authService must not be called") }
    var contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: contactService must not be called") }
    var keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: keyService must not be called") }
    var mediaService: Sanchr_Media_MediaServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: mediaService must not be called") }
    var settingsService: Sanchr_Settings_SettingsServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: settingsService must not be called") }
    var notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: notificationService must not be called") }
    var vaultService: Sanchr_Vault_VaultServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: vaultService must not be called") }
    var backupService: Sanchr_Backup_BackupServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: backupService must not be called") }
    var discoveryService: Sanchr_Discovery_DiscoveryServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: discoveryService must not be called") }
    var callSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol {
        fatalError("PresenceGRPCClient: callSignalingService must not be called") }
}

/// Minimal messaging service spy — only registers/consumes sendSealedMessage.
@available(swift, deprecated: 5.6)
private final class PresenceSpyMessagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol,
    @unchecked Sendable
{
    let channel: GRPCChannel
    var defaultCallOptions: CallOptions = CallOptions()
    var interceptors: Sanchr_Messaging_MessagingServiceClientInterceptorFactoryProtocol? = nil
    let fakeChannel: FakeChannel

    init() {
        let fc = FakeChannel()
        self.fakeChannel = fc
        self.channel = fc
    }

    func registerSealedResponse() {
        var resp = Sanchr_Messaging_SendSealedMessageResponse()
        resp.serverTimestamp = 1_700_000_000_000
        let fake = fakeChannel.makeFakeUnaryResponse(
            path: Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendSealedMessage.path,
            requestHandler: { _ in }
        ) as FakeUnaryResponse<Sanchr_Messaging_SendSealedMessageRequest, Sanchr_Messaging_SendSealedMessageResponse>
        try? fake.sendMessage(resp)
    }

    // ── Required make*Call stubs ──

    func makeSendSealedMessageCall(_ request: Sanchr_Messaging_SendSealedMessageRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_SendSealedMessageRequest, Sanchr_Messaging_SendSealedMessageResponse> {
        fatalError("makeSendSealedMessageCall must not be called directly")
    }
    func makeSendMessageCall(_ request: Sanchr_Messaging_SendMessageRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_SendMessageRequest, Sanchr_Messaging_SendMessageResponse> {
        fatalError("makeSendMessageCall must not be called")
    }
    func makeStartDirectConversationCall(_ request: Sanchr_Messaging_StartDirectConversationRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_StartDirectConversationRequest, Sanchr_Messaging_Conversation> {
        fatalError("makeStartDirectConversationCall must not be called")
    }
    func makeMessageStreamCall(callOptions: CallOptions?)
        -> GRPCAsyncBidirectionalStreamingCall<Sanchr_Messaging_ClientEvent, Sanchr_Messaging_ServerEvent> {
        fatalError("makeMessageStreamCall must not be called")
    }
    func makeSyncMessagesCall(_ request: Sanchr_Messaging_SyncRequest, callOptions: CallOptions?)
        -> GRPCAsyncServerStreamingCall<Sanchr_Messaging_SyncRequest, Sanchr_Messaging_EncryptedEnvelope> {
        fatalError("makeSyncMessagesCall must not be called")
    }
    func makeAckMessagesCall(_ request: Sanchr_Messaging_AckMessagesRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_AckMessagesRequest, Sanchr_Messaging_AckMessagesResponse> {
        fatalError("makeAckMessagesCall must not be called")
    }
    func makeDeleteMessageCall(_ request: Sanchr_Messaging_DeleteMessageRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_DeleteMessageRequest, Sanchr_Messaging_DeleteMessageResponse> {
        fatalError("makeDeleteMessageCall must not be called")
    }
    func makeEditMessageCall(_ request: Sanchr_Messaging_EditMessageRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_EditMessageRequest, Sanchr_Messaging_EditMessageResponse> {
        fatalError("makeEditMessageCall must not be called")
    }
    func makeSendReceiptCall(_ request: Sanchr_Messaging_ReceiptRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_ReceiptRequest, Sanchr_Messaging_ReceiptResponse> {
        fatalError("makeSendReceiptCall must not be called")
    }
    func makeGetConversationsCall(_ request: Sanchr_Messaging_GetConversationsRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_GetConversationsRequest, Sanchr_Messaging_GetConversationsResponse> {
        fatalError("makeGetConversationsCall must not be called")
    }
    func makeSendReactionCall(_ request: Sanchr_Messaging_Reaction, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_Reaction, Sanchr_Messaging_Reaction> {
        fatalError("makeSendReactionCall must not be called")
    }
    func makeGetSenderCertificateCall(_ request: Sanchr_Messaging_SenderCertificateRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_SenderCertificateRequest, Sanchr_Messaging_SenderCertificateResponse> {
        fatalError("makeGetSenderCertificateCall must not be called")
    }
    func makeGetDeliveryTokensCall(_ request: Sanchr_Messaging_DeliveryTokenRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Messaging_DeliveryTokenRequest, Sanchr_Messaging_DeliveryTokenResponse> {
        fatalError("makeGetDeliveryTokensCall must not be called")
    }
}

// MARK: - Factory

@available(swift, deprecated: 5.6)
private func makePresenceRepo(
    spy: PresenceSpyMessagingService,
    sealedManager: SealedSenderManagerProtocol,
    privacySettings: PrivacySettingsCache = PrivacySettingsCache(),
    currentUserId: @escaping @Sendable () -> String? = { "alice" }
) -> MessageRepositoryImpl {
    let grpcClient = PresenceGRPCClient(messagingService: spy)
    let stubAccess = StubAccessKeyStoreForPresence()
    let mediaDownload = MediaDownloadManager(
        mediaEncryption: StubMediaEncryptionForPresence(),
        accessKeyStore: stubAccess,
        grpcClient: grpcClient,
        vaultEKFScheduler: VaultEKFScheduler(accessKeyStore: stubAccess)
    )
    return MessageRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: PresenceLocalDatabase(),
        signalProtocol: MinimalSignalProtocol(),
        sealedSenderManager: sealedManager,
        chatVaultPolicyMirror: ChatVaultPolicyMirror(),
        vaultRepository: StubVaultRepositoryForPresence(),
        mediaDownloadManager: mediaDownload,
        currentUserIdProvider: currentUserId,
        privacySettings: privacySettings,
        profileKeyStore: ProfileKeyStore(keychain: MockKeychainService())
    )
}

private final class StubVaultRepositoryForPresence: VaultRepositoryProtocol, @unchecked Sendable {
    func fetchItems() async throws -> [VaultItem] { [] }
    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws -> VaultItem {
        fatalError("StubVaultRepositoryForPresence: uploadItem must not be called")
    }
    func downloadItem(id: String) async throws -> Data {
        fatalError("StubVaultRepositoryForPresence: downloadItem must not be called")
    }
    func deleteItem(id: String) async throws {
        fatalError("StubVaultRepositoryForPresence: deleteItem must not be called")
    }
    func storageUsed() async throws -> Int64 { 0 }
}

private final class StubAccessKeyStoreForPresence: AccessKeyStoreProtocol, @unchecked Sendable {
    func store(mediaId: String, accessKey: Data, conversationId: String, kind: AccessKeyEntry.Kind) async throws {}
    func retrieve(mediaId: String) async throws -> Data? { nil }
    func retrieveEntry(mediaId: String) async throws -> AccessKeyEntry? { nil }
    func touch(mediaId: String) async throws {}
    func getAndTouch(mediaId: String) async throws -> Data? { nil }
    func purgeExpired() async throws -> Int { 0 }
    func deleteAll() async throws {}
}

private final class StubMediaEncryptionForPresence: MediaEncryptionProtocol, @unchecked Sendable {
    func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data) { (data, Data(), Data()) }
    func encrypt(data: Data, withKey key: Data) throws -> Data { data }
    func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data { ciphertext }
    func encryptFile(at inputURL: URL, to outputURL: URL) async throws -> MediaEncryptionMetadata {
        fatalError("not used")
    }
    func decryptFile(at inputURL: URL, to outputURL: URL, metadata: MediaEncryptionMetadata) async throws {
        fatalError("not used")
    }
    func encryptFile(at inputURL: URL, to outputURL: URL, withKey keyData: Data) async throws -> MediaEncryptionMetadata {
        fatalError("not used")
    }
}

// MARK: - Tests

@available(swift, deprecated: 5.6)
final class P2PPresenceTests: XCTestCase {

    /// `sendP2PPresence` must encode the sealed inner payload with
    /// `contentType == "presence/v1"` so the server cannot distinguish it
    /// from a regular chat message.
    func test_sendP2PPresence_usesPresenceV1ContentType() async throws {
        let spy = PresenceSpyMessagingService()
        spy.registerSealedResponse()

        let capturing = CapturingSealedSenderManager()
        let repo = makePresenceRepo(spy: spy, sealedManager: capturing)

        try await repo.sendP2PPresence(
            recipientUserId: "bob",
            statusCode: .online,
            lastSeenMs: 0
        )

        XCTAssertEqual(
            capturing.capturedContentType, "presence/v1",
            "P2P presence must use contentType 'presence/v1' so the server cannot identify it"
        )
    }

    /// `sendP2PPresence` must set `conversationId` to an empty string —
    /// presence has no conversation context, and including one would leak
    /// which conversation is active to the server.
    func test_sendP2PPresence_hasNoConversationId() async throws {
        let spy = PresenceSpyMessagingService()
        spy.registerSealedResponse()

        let capturing = CapturingSealedSenderManager()
        let repo = makePresenceRepo(spy: spy, sealedManager: capturing)

        try await repo.sendP2PPresence(
            recipientUserId: "bob",
            statusCode: .online,
            lastSeenMs: 0
        )

        XCTAssertEqual(
            capturing.capturedConversationId, "",
            "P2P presence envelope must not carry a conversation ID"
        )
    }

    /// When `online_status_visible` is off, presence is still sent to tracked
    /// peers, but the payload is HIDDEN instead of ONLINE so recipients can
    /// clear stale online state without learning foreground/background state.
    func test_sendP2PPresence_sendsHiddenWhenOnlineStatusHidden() async throws {
        let spy = PresenceSpyMessagingService()
        spy.registerSealedResponse()

        let privacySettings = PrivacySettingsCache()
        var settings = Sanchr_Settings_UserSettings()
        settings.onlineStatusVisible = false
        settings.readReceipts = true
        settings.typingIndicator = true
        settings.sanchrModeEnabled = false
        settings.profilePhotoVisibility = "everyone"
        privacySettings.update(from: settings)

        let capturing = CapturingSealedSenderManager()
        let repo = makePresenceRepo(spy: spy, sealedManager: capturing, privacySettings: privacySettings)

        try await repo.sendP2PPresence(
            recipientUserId: "bob",
            statusCode: .online,
            lastSeenMs: 0
        )

        let sealedPath = Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendSealedMessage.path
        XCTAssertFalse(
            spy.fakeChannel.hasFakeResponseEnqueued(forPath: sealedPath),
            "sendSealedMessage must be called once to publish the HIDDEN state"
        )
        let payload = try XCTUnwrap(capturing.capturedContent)
        let update = try Sanchr_Messaging_PresenceUpdate(serializedBytes: payload)
        XCTAssertEqual(update.userID, "alice")
        XCTAssertEqual(update.statusCode, .hidden)
    }

    func test_sendP2PPresence_suppressedWhenSanchrModeEnabled() async throws {
        let spy = PresenceSpyMessagingService()
        spy.registerSealedResponse()

        let privacySettings = PrivacySettingsCache()
        var settings = Sanchr_Settings_UserSettings()
        settings.onlineStatusVisible = true
        settings.readReceipts = true
        settings.typingIndicator = true
        settings.sanchrModeEnabled = true
        settings.profilePhotoVisibility = "everyone"
        privacySettings.update(from: settings)

        let capturing = CapturingSealedSenderManager()
        let repo = makePresenceRepo(spy: spy, sealedManager: capturing, privacySettings: privacySettings)

        try await repo.sendP2PPresence(
            recipientUserId: "bob",
            statusCode: .online,
            lastSeenMs: 0
        )

        let sealedPath = Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendSealedMessage.path
        XCTAssertTrue(
            spy.fakeChannel.hasFakeResponseEnqueued(forPath: sealedPath),
            "sendSealedMessage must not be called while Sanchr Mode suppresses presence"
        )
        XCTAssertNil(capturing.capturedContentType)
    }

    func test_sendP2PPresence_requiresCurrentUserId() async throws {
        let spy = PresenceSpyMessagingService()
        spy.registerSealedResponse()

        let capturing = CapturingSealedSenderManager()
        let repo = makePresenceRepo(
            spy: spy,
            sealedManager: capturing,
            currentUserId: { nil }
        )

        try await repo.sendP2PPresence(
            recipientUserId: "bob",
            statusCode: .online,
            lastSeenMs: 0
        )

        let sealedPath = Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendSealedMessage.path
        XCTAssertTrue(spy.fakeChannel.hasFakeResponseEnqueued(forPath: sealedPath))
        XCTAssertNil(capturing.capturedContentType)
    }
}
