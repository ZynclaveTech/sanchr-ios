// Tests/UnitTests/MessageRepositorySealedSendTests.swift
import XCTest
import GRPC
import NIOCore
import NIOEmbedded
import SanchrShared
@testable import Sanchr

// MARK: - Spy messaging service

/// Tracks which send RPC path was actually invoked by `MessageRepositoryImpl`.
///
/// Swift protocol extension dispatch means the async convenience methods
/// (`sendMessage`, `sendSealedMessage`) on `Sanchr_Messaging_MessagingServiceAsyncClientProtocol`
/// are dispatched through `performAsyncUnaryCall` → `channel.makeAsyncUnaryCall` → `FakeChannel`.
/// Overriding the async methods in the conforming type does NOT intercept calls made through
/// the protocol type (witness-table dispatch calls the extension default, not the override).
///
/// The correct interception point is the `FakeChannel` itself: pre-register a
/// `FakeUnaryResponse` for each expected call, and increment counters in the
/// request handler. This gives accurate call-count tracking regardless of whether
/// the caller uses the protocol or the concrete type.
@available(swift, deprecated: 5.6)
private final class SpyMessagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol,
    @unchecked Sendable
{
    // MARK: GRPCClient conformance

    let channel: GRPCChannel
    var defaultCallOptions: CallOptions = CallOptions()
    var interceptors: Sanchr_Messaging_MessagingServiceClientInterceptorFactoryProtocol? = nil

    /// Exposed so tests can query which RPC path was consumed via
    /// `hasFakeResponseEnqueued(forPath:)` — a synchronous, race-free alternative
    /// to the `requestHandler` counter approach (the handler fires on the
    /// EmbeddedEventLoop and may not be visible to the calling thread before
    /// assertions run).
    let fakeChannel: FakeChannel

    // MARK: Init — pre-register fake responses for both RPC paths

    init() {
        let fc = FakeChannel()
        self.fakeChannel = fc
        self.channel = fc
    }

    /// Register one fake response for the `sendSealedMessage` RPC so a single
    /// `repo.sendMessage()` call can succeed and be counted. Call this once per
    /// test that exercises the sealed path.
    func registerSealedResponse() {
        var responseMsg = Sanchr_Messaging_SendSealedMessageResponse()
        responseMsg.serverTimestamp = 1_700_000_000_000
        let fake = fakeChannel.makeFakeUnaryResponse(
            path: Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendSealedMessage.path,
            requestHandler: { _ in }
        ) as FakeUnaryResponse<Sanchr_Messaging_SendSealedMessageRequest, Sanchr_Messaging_SendSealedMessageResponse>
        try? fake.sendMessage(responseMsg)
    }

    /// Register one fake response for the plain `sendMessage` RPC.
    func registerPlainResponse() {
        let fake = fakeChannel.makeFakeUnaryResponse(
            path: Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendMessage.path,
            requestHandler: { _ in }
        ) as FakeUnaryResponse<Sanchr_Messaging_SendMessageRequest, Sanchr_Messaging_SendMessageResponse>
        try? fake.sendMessage(Sanchr_Messaging_SendMessageResponse())
    }

    // MARK: make*Call stubs — required by the protocol but not called by the async extension path

    func makeSendMessageCall(
        _ request: Sanchr_Messaging_SendMessageRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_SendMessageRequest, Sanchr_Messaging_SendMessageResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeStartDirectConversationCall(
        _ request: Sanchr_Messaging_StartDirectConversationRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_StartDirectConversationRequest, Sanchr_Messaging_Conversation> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeMessageStreamCall(
        callOptions: CallOptions?
    ) -> GRPCAsyncBidirectionalStreamingCall<Sanchr_Messaging_ClientEvent, Sanchr_Messaging_ServerEvent> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeSyncMessagesCall(
        _ request: Sanchr_Messaging_SyncRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncServerStreamingCall<Sanchr_Messaging_SyncRequest, Sanchr_Messaging_EncryptedEnvelope> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeAckMessagesCall(
        _ request: Sanchr_Messaging_AckMessagesRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_AckMessagesRequest, Sanchr_Messaging_AckMessagesResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeDeleteMessageCall(
        _ request: Sanchr_Messaging_DeleteMessageRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_DeleteMessageRequest, Sanchr_Messaging_DeleteMessageResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeSendReceiptCall(
        _ request: Sanchr_Messaging_ReceiptRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_ReceiptRequest, Sanchr_Messaging_ReceiptResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeGetConversationsCall(
        _ request: Sanchr_Messaging_GetConversationsRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_GetConversationsRequest, Sanchr_Messaging_GetConversationsResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeGetPresenceSnapshotCall(
        _ request: Sanchr_Messaging_GetPresenceSnapshotRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_GetPresenceSnapshotRequest, Sanchr_Messaging_GetPresenceSnapshotResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeSendReactionCall(
        _ request: Sanchr_Messaging_Reaction,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_Reaction, Sanchr_Messaging_Reaction> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeGetSenderCertificateCall(
        _ request: Sanchr_Messaging_SenderCertificateRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_SenderCertificateRequest, Sanchr_Messaging_SenderCertificateResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeGetDeliveryTokensCall(
        _ request: Sanchr_Messaging_DeliveryTokenRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_DeliveryTokenRequest, Sanchr_Messaging_DeliveryTokenResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func makeSendSealedMessageCall(
        _ request: Sanchr_Messaging_SendSealedMessageRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Messaging_SendSealedMessageRequest, Sanchr_Messaging_SendSealedMessageResponse> {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
}

// MARK: - Stub GRPC client

/// Minimal GRPCClientProtocol conformance for the send path.
/// Only `messagingService` is needed; all other service accessors crash to
/// catch accidental calls early.
private final class StubGRPCClient: GRPCClientProtocol, @unchecked Sendable {
    let messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol

    init(messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol) {
        self.messagingService = messagingService
    }

    // Lifecycle — no-ops for tests
    func connect() async throws {}
    func disconnect() async throws {}
    var isConnected: Bool { false }

    // Services not involved in the send path — crash to surface accidental calls
    var authService: Sanchr_Auth_AuthServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: authService must not be called in this test") }
    var contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: contactService must not be called in this test") }
    var keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: keyService must not be called in this test") }
    var mediaService: Sanchr_Media_MediaServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: mediaService must not be called in this test") }
    var settingsService: Sanchr_Settings_SettingsServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: settingsService must not be called in this test") }
    var notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: notificationService must not be called in this test") }
    var vaultService: Sanchr_Vault_VaultServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: vaultService must not be called in this test") }
    var backupService: Sanchr_Backup_BackupServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: backupService must not be called in this test") }
    var discoveryService: Sanchr_Discovery_DiscoveryServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: discoveryService must not be called in this test") }
    var callSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol {
        fatalError("StubGRPCClient: callSignalingService must not be called in this test") }
}

// MARK: - Stub LocalDatabase (minimal for send path)

/// Only `fetchConversation` and `saveMessage` are called by `sendMessage`.
/// All other methods crash to catch accidental calls.
private final class StubLocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {

    func fetchConversation(id: String) async throws -> Conversation? {
        let alice = User(
            id: "alice",
            phoneNumber: "+10000000001",
            displayName: "Alice",
            isVerified: false,
            status: .online,
            isLocalUser: true
        )
        let bob = User(
            id: "bob",
            phoneNumber: "+10000000002",
            displayName: "Bob",
            isVerified: false,
            status: .online,
            isLocalUser: false
        )
        return Conversation(
            id: "conv-1",
            participants: [alice, bob],
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func saveMessage(_ message: Message) async throws {}

    // ── All remaining protocol requirements — crash to surface accidental calls ──

    func saveIncomingMessageAndQueueAck(_ message: Message) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func deleteMessage(id: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func saveConversation(_ conversation: Conversation) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchConversations() async throws -> [Conversation] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func deleteConversation(id: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func saveContact(_ user: User) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchContacts() async throws -> [User] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func searchContacts(query: String) async throws -> [User] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func saveVaultItem(_ item: VaultItem) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchVaultItems() async throws -> [VaultItem] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchAllVaultItems() async throws -> [VaultItem] { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func deleteVaultItem(id: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func updateAccessKeyEntryLastAccessed(mediaId: String, lastAccessedAt: Date) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func deleteAccessKeyEntry(mediaId: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func deleteAllAccessKeyEntries() async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func clearAppearanceOverride(conversationId: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func setVaultPolicy(_ policy: ChatVaultPolicy) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func clearVaultPolicy(conversationId: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func fetchMessageById(_ messageId: String) async throws -> Message? { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func hasLocalHistory() async throws -> Bool { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func exportBackupSnapshot(currentUserId: String?, fingerprint: String) async throws -> BackupArchiveSnapshot { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?, localFingerprint: String) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func purgeAllData() async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func updateUserPresence(userId: String, status: User.Status, lastSeen: Date?) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
    func updateConversationLastMessageStatusIfMatches(
        conversationId: String, messageId: String, status: Message.DeliveryStatus
    ) async throws { fatalError("StubLocalDatabase: \(#function) must not be called in this test") }
}

// MARK: - Stub Signal protocol

private final class StubSignalProtocol: SignalProtocolManagerProtocol, @unchecked Sendable {
    let localUserId: String = "alice"

    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws
        -> [Sanchr_Messaging_DeviceMessage]
    {
        var dm = Sanchr_Messaging_DeviceMessage()
        dm.recipientID = recipientId
        dm.deviceID = 1
        dm.ciphertext = Data("fake-ciphertext".utf8)
        return [dm]
    }

    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data { plaintext }
    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data { ciphertext }
    func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { Data() }
    func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
        throw AppError.decryptionFailed(reason: "not used")
    }
    func establishSession(with userId: String, deviceId: Int32) async throws {}
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
    func hasSession(with userId: String) -> Bool { true }
    func resetSession(with userId: String, deviceId: Int32) throws {}
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
    func markIdentityVerified(userId: String) {}
    func isIdentityVerified(userId: String) -> Bool { false }
    func localIdentityKeyData() throws -> Data { Data() }
    func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
}

// MARK: - Stub SealedSenderManager

// Not `final` — TrackingTokenManager in test_sendMessage_acquiresDeliveryToken subclasses this.
private class StubSealedSenderManager: SealedSenderManagerProtocol, @unchecked Sendable {
    func acquireDeliveryToken() async throws -> Data { Data("tok".utf8) }
    func getSenderCertificate() async throws -> Data { Data() }
    func encodeInnerPayload(conversationId: String, contentType: String, content: Data, isSync: Bool) throws -> Data {
        content
    }
    func decodeInnerPayload(_ data: Data) throws -> InnerPayload {
        InnerPayload(conversationId: "", contentType: "", content: Data(), isSync: false)
    }
    static func isInnerPayload(_ data: Data) -> Bool { false }
    func replenishIfNeeded() async {}
}

// MARK: - Stub VaultRepository

private final class StubVaultRepository: VaultRepositoryProtocol, @unchecked Sendable {
    func fetchItems() async throws -> [VaultItem] { [] }
    func uploadItem(data: Data, name: String, type: VaultItem.VaultItemType) async throws -> VaultItem {
        fatalError("StubVaultRepository: uploadItem must not be called in this test")
    }
    func downloadItem(id: String) async throws -> Data {
        fatalError("StubVaultRepository: downloadItem must not be called in this test")
    }
    func deleteItem(id: String) async throws {
        fatalError("StubVaultRepository: deleteItem must not be called in this test")
    }
    func storageUsed() async throws -> Int64 { 0 }
}

// MARK: - Stub AccessKeyStore (for MediaDownloadManager)

private final class StubAccessKeyStore: AccessKeyStoreProtocol, @unchecked Sendable {
    func store(mediaId: String, accessKey: Data, conversationId: String, kind: AccessKeyEntry.Kind) async throws {}
    func retrieve(mediaId: String) async throws -> Data? { nil }
    func retrieveEntry(mediaId: String) async throws -> AccessKeyEntry? { nil }
    func touch(mediaId: String) async throws {}
    func getAndTouch(mediaId: String) async throws -> Data? { nil }
    func purgeExpired() async throws -> Int { 0 }
    func deleteAll() async throws {}
}

// MARK: - Stub MediaEncryption (for MediaDownloadManager)

private final class StubMediaEncryption: MediaEncryptionProtocol, @unchecked Sendable {
    func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data) {
        (ciphertext: data, key: Data(), iv: Data())
    }
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

// MARK: - Factory helpers

private func makeMediaDownloadManager(grpcClient: GRPCClientProtocol) -> MediaDownloadManager {
    MediaDownloadManager(
        mediaEncryption: StubMediaEncryption(),
        accessKeyStore: StubAccessKeyStore(),
        grpcClient: grpcClient,
        vaultEKFScheduler: VaultEKFScheduler(accessKeyStore: StubAccessKeyStore())
    )
}

private func makeRepo(spyService: SpyMessagingService) -> MessageRepositoryImpl {
    let grpcClient = StubGRPCClient(messagingService: spyService)
    return MessageRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: StubLocalDatabase(),
        signalProtocol: StubSignalProtocol(),
        sealedSenderManager: StubSealedSenderManager(),
        chatVaultPolicyMirror: ChatVaultPolicyMirror(),
        vaultRepository: StubVaultRepository(),
        mediaDownloadManager: makeMediaDownloadManager(grpcClient: grpcClient),
        currentUserIdProvider: { "alice" },
        privacySettings: PrivacySettingsCache()
    )
}

// MARK: - Tests

final class MessageRepositorySealedSendTests: XCTestCase {

    /// After the sealed-sender migration, `sendMessage` must call
    /// `sendSealedMessage` on the messaging service — never the plain `sendMessage` RPC.
    func test_sendMessage_callsSealedRPC_notRegularRPC() async throws {
        let spy = SpyMessagingService()
        // Register one response for whichever RPC the implementation currently calls.
        // After the Task 2 migration this should be a sealed response; until then,
        // we pre-register BOTH so the call succeeds regardless, letting assertions drive the FAIL.
        spy.registerSealedResponse()
        spy.registerPlainResponse()
        let repo = makeRepo(spyService: spy)
        let message = Message(
            id: "msg-1",
            conversationId: "conv-1",
            senderId: "alice",
            timestamp: Date(),
            content: .text("hello"),
            status: .sending,
            isOutgoing: true
        )

        _ = try await repo.sendMessage(message)

        // The FakeChannel dequeues a registered response synchronously when makeCall
        // is invoked, so hasFakeResponseEnqueued is a reliable, race-free signal of
        // which RPC path was taken — unlike the requestHandler counter which fires on
        // the EmbeddedEventLoop and may not be visible before these assertions run.
        // hasFakeResponseEnqueued returns true if unconsumed, false if consumed by a call.
        let sealedPath = Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendSealedMessage.path
        let plainPath = Sanchr_Messaging_MessagingServiceClientMetadata.Methods.sendMessage.path

        XCTAssertFalse(
            spy.fakeChannel.hasFakeResponseEnqueued(forPath: sealedPath),
            "sendSealedMessage fake must have been consumed — sealed RPC must be called exactly once"
        )
        XCTAssertTrue(
            spy.fakeChannel.hasFakeResponseEnqueued(forPath: plainPath),
            "plain sendMessage fake must remain unused — sender identity must be hidden from server"
        )
    }

    /// The delivery token must be consumed on every send — proves the token is
    /// actually threaded through the request rather than acquired and discarded.
    func test_sendMessage_acquiresDeliveryToken() async throws {
        final class TrackingTokenManager: StubSealedSenderManager {
            private(set) var acquireCallCount = 0
            override func acquireDeliveryToken() async throws -> Data {
                acquireCallCount += 1
                return Data("tok".utf8)
            }
        }

        let spy = SpyMessagingService()
        // Pre-register both responses so the send succeeds and we can observe
        // whether acquireDeliveryToken was called.
        spy.registerSealedResponse()
        spy.registerPlainResponse()
        let tokenManager = TrackingTokenManager()
        let grpcClient = StubGRPCClient(messagingService: spy)
        let repo = MessageRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: StubLocalDatabase(),
            signalProtocol: StubSignalProtocol(),
            sealedSenderManager: tokenManager,
            chatVaultPolicyMirror: ChatVaultPolicyMirror(),
            vaultRepository: StubVaultRepository(),
            mediaDownloadManager: makeMediaDownloadManager(grpcClient: grpcClient),
            currentUserIdProvider: { "alice" },
            privacySettings: PrivacySettingsCache()
        )
        let message = Message(
            id: "msg-2",
            conversationId: "conv-1",
            senderId: "alice",
            timestamp: Date(),
            content: .text("hi"),
            status: .sending,
            isOutgoing: true
        )

        _ = try await repo.sendMessage(message)

        XCTAssertEqual(tokenManager.acquireCallCount, 1,
            "A delivery token must be acquired for every outgoing message")
    }
}
