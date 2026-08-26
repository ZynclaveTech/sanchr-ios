import XCTest
import GRPC
import NIOCore
import NIOEmbedded
import SanchrShared
@testable import Sanchr

// MARK: - Spy contacts service

/// Wraps a FakeChannel so pre-registered responses are dispatched correctly
/// through the protocol extension's `makeAsyncUnaryCall` path.
@available(swift, deprecated: 5.6)
private final class SpyContactsService: Sanchr_Contacts_ContactServiceAsyncClientProtocol,
    @unchecked Sendable
{
    let channel: GRPCChannel
    var defaultCallOptions: CallOptions = CallOptions()
    var interceptors: Sanchr_Contacts_ContactServiceClientInterceptorFactoryProtocol? = nil

    let fakeChannel: FakeChannel

    init() {
        let fc = FakeChannel()
        self.fakeChannel = fc
        self.channel = fc
    }

    func registerGetContactsResponse(_ response: Sanchr_Contacts_GetContactsResponse) {
        let fake = fakeChannel.makeFakeUnaryResponse(
            path: Sanchr_Contacts_ContactServiceClientMetadata.Methods.getContacts.path,
            requestHandler: { _ in }
        ) as FakeUnaryResponse<Sanchr_Contacts_GetContactsRequest, Sanchr_Contacts_GetContactsResponse>
        try? fake.sendMessage(response)
    }

    // Required make*Call stubs — not invoked through the protocol extension default.
    func makeSyncContactsCall(_ r: Sanchr_Contacts_SyncContactsRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_SyncContactsRequest, Sanchr_Contacts_SyncContactsResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeGetContactsCall(_ r: Sanchr_Contacts_GetContactsRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_GetContactsRequest, Sanchr_Contacts_GetContactsResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeBlockContactCall(_ r: Sanchr_Contacts_BlockContactRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_BlockContactRequest, Sanchr_Contacts_BlockContactResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeUnblockContactCall(_ r: Sanchr_Contacts_UnblockContactRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_UnblockContactRequest, Sanchr_Contacts_UnblockContactResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeGetBlockedListCall(_ r: Sanchr_Contacts_GetBlockedListRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_GetBlockedListRequest, Sanchr_Contacts_GetBlockedListResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }
}

// MARK: - Stub GRPC client (contacts path only)

private final class StubGRPCClientForContacts: GRPCClientProtocol, @unchecked Sendable {
    let contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol

    init(contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol) {
        self.contactService = contactService
    }

    func connect() async throws {}
    func disconnect() async throws {}
    var isConnected: Bool { false }

    var authService: Sanchr_Auth_AuthServiceAsyncClientProtocol
        { fatalError("not used") }
    var messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol
        { fatalError("not used") }
    var keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol
        { fatalError("not used") }
    var mediaService: Sanchr_Media_MediaServiceAsyncClientProtocol
        { fatalError("not used") }
    var settingsService: Sanchr_Settings_SettingsServiceAsyncClientProtocol
        { fatalError("not used") }
    var notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol
        { fatalError("not used") }
    var vaultService: Sanchr_Vault_VaultServiceAsyncClientProtocol
        { fatalError("not used") }
    var backupService: Sanchr_Backup_BackupServiceAsyncClientProtocol
        { fatalError("not used") }
    var discoveryService: Sanchr_Discovery_DiscoveryServiceAsyncClientProtocol
        { fatalError("not used") }
    var callSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol
        { fatalError("not used") }
}

// MARK: - Stub local database (only saveContact needed)

private final class StubLocalDatabaseForContacts: LocalDatabaseProtocol, @unchecked Sendable {
    func saveContact(_ user: User) async throws { /* no-op — not the focus of these tests */ }

    // All other methods: fatalError to catch accidental calls.
    func saveMessage(_ m: Message) async throws { fatalError() }
    func saveIncomingMessageAndQueueAck(_ m: Message) async throws { fatalError() }
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { fatalError() }
    func deleteMessage(id: String) async throws { fatalError() }
    func purgeExpiredMessages() async throws -> [String] { [] }
    func deleteAllMessages(conversationId: String) async throws -> [String] { [] }
    func disappearingDuration(conversationId: String) async throws -> Int64 { 0 }
    func setDisappearingDuration(conversationId: String, seconds: Int64) async throws {}
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { fatalError() }
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws { fatalError() }
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { fatalError() }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { fatalError() }
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { fatalError() }
    func saveConversation(_ c: Conversation) async throws { fatalError() }
    func fetchConversation(id: String) async throws -> Conversation? { fatalError() }
    func fetchConversations() async throws -> [Conversation] { fatalError() }
    func deleteConversation(id: String) async throws { fatalError() }
    func fetchContacts() async throws -> [User] { fatalError() }
    func searchContacts(query: String) async throws -> [User] { fatalError() }
    func saveVaultItem(_ item: VaultItem) async throws { fatalError() }
    func fetchVaultItems() async throws -> [VaultItem] { fatalError() }
    func fetchAllVaultItems() async throws -> [VaultItem] { fatalError() }
    func deleteVaultItem(id: String) async throws { fatalError() }
    func saveAccessKeyEntry(_ e: AccessKeyEntry) async throws { fatalError() }
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { fatalError() }
    func updateAccessKeyEntryLastAccessed(mediaId: String, lastAccessedAt: Date) async throws { fatalError() }
    func deleteAccessKeyEntry(mediaId: String) async throws { fatalError() }
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { fatalError() }
    func deleteAllAccessKeyEntries() async throws { fatalError() }
    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { fatalError() }
    func setAppearanceOverride(_ o: AppearanceOverride, for conversationId: String) async throws { fatalError() }
    func clearAppearanceOverride(conversationId: String) async throws { fatalError() }
    func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? { fatalError() }
    func setVaultPolicy(_ p: ChatVaultPolicy, for conversationId: String) async throws { fatalError() }
}

// MARK: - Tests

final class ContactRepositoryDecryptTests: XCTestCase {
    private let crypto = ProfileCryptor()
    private let profileKey = Data(repeating: 0xAB, count: 32)

    /// `locallyKnownKeys` seeds keys as if they had arrived over the Signal
    /// session. Keys offered by the server in the response are deliberately not
    /// trusted, so a test that wants decryption must seed one here.
    private func makeSUT(
        contactsService: SpyContactsService,
        locallyKnownKeys: [String: Data] = [:]
    ) -> ContactRepositoryImpl {
        let store = ProfileKeyStore(keychain: MockKeychainService())
        for (userId, key) in locallyKnownKeys {
            try? store.saveContactProfileKey(key, forUserId: userId)
        }
        return ContactRepositoryImpl(
            grpcClient: StubGRPCClientForContacts(contactService: contactsService),
            localDatabase: StubLocalDatabaseForContacts(),
            profileKeyStore: store,
            profileCrypto: crypto
        )
    }

    func test_fetchContacts_withProfileKey_decryptsDisplayName() async throws {
        // Arrange: encrypt "Alice" with the known profile key
        let encryptedName = try crypto.encryptField("Alice", profileKey: profileKey, field: .displayName)

        var contact = Sanchr_Contacts_Contact()
        contact.userID       = "user-1"
        contact.phoneNumber  = "+15555555555"
        contact.displayName  = "REDACTED"       // plaintext the server would normally send
        contact.profileKey   = profileKey
        contact.encryptedDisplayName = encryptedName

        var response = Sanchr_Contacts_GetContactsResponse()
        response.contacts = [contact]

        let service = SpyContactsService()
        service.registerGetContactsResponse(response)
        let sut = makeSUT(
            contactsService: service,
            locallyKnownKeys: ["user-1": profileKey]
        )

        // Act
        let users = try await sut.fetchContacts()

        // Assert
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].displayName, "Alice",
                       "should use decrypted value, not server-provided plaintext 'REDACTED'")
    }

    /// Previously asserted the display name fell back to the server's plaintext,
    /// which is exactly the leak the profile encryption exists to prevent. Until a
    /// key arrives over the Signal session we show the phone number instead.
    func test_fetchContacts_noLocalProfileKey_showsPhoneNumberNotServerPlaintext() async throws {
        // Arrange: contact with no locally-known profile key
        var contact = Sanchr_Contacts_Contact()
        contact.userID      = "user-2"
        contact.phoneNumber = "+15551234567"
        contact.displayName = "Bob"
        // profileKey is empty (default Data())

        var response = Sanchr_Contacts_GetContactsResponse()
        response.contacts = [contact]

        let service = SpyContactsService()
        service.registerGetContactsResponse(response)
        let sut = makeSUT(contactsService: service)

        // Act
        let users = try await sut.fetchContacts()

        // Assert
        XCTAssertEqual(users[0].displayName, "+15551234567",
                       "must fall back to the phone number, never the server's plaintext")
        XCTAssertNotEqual(users[0].displayName, "Bob",
                          "server-supplied plaintext must never reach the UI")
    }

    /// A key offered by the server is ignored outright — the server also holds the
    /// ciphertext, so honouring its key would let it choose what we decrypt.
    func test_fetchContacts_serverSuppliedProfileKey_isIgnored() async throws {
        // Arrange: server offers a key; no key is known locally
        let wrongKey = Data(repeating: 0xFF, count: 32)
        let encryptedWithCorrectKey = try crypto.encryptField("Alice", profileKey: profileKey, field: .displayName)

        var contact = Sanchr_Contacts_Contact()
        contact.userID       = "user-3"
        contact.phoneNumber  = "+15559876543"
        contact.displayName  = "Fallback"
        contact.profileKey   = wrongKey  // key that won't decrypt the ciphertext
        contact.encryptedDisplayName = encryptedWithCorrectKey

        var response = Sanchr_Contacts_GetContactsResponse()
        response.contacts = [contact]

        let service = SpyContactsService()
        service.registerGetContactsResponse(response)
        let sut = makeSUT(contactsService: service)

        // Act — must not throw
        let users = try await sut.fetchContacts()

        // Assert: server key ignored, server plaintext ignored
        XCTAssertEqual(users[0].displayName, "+15559876543",
                       "a server-offered profile key must not be used")
        XCTAssertNotEqual(users[0].displayName, "Fallback")
    }
}
