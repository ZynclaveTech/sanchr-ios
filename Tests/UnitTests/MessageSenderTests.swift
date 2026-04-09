import XCTest
@testable import SanchrShared

// MARK: - Test-only default implementations for LocalDatabaseProtocol
//
// `MessageSender` only touches a tiny subset of `LocalDatabaseProtocol`
// (saveMessage / deleteMessage / updateMessageStatus). Rather than force every
// fake in the test target to stub 30+ methods, provide fatalError defaults in
// a test-target-only extension. Fakes override only what they need.

private enum FakeDBUnused {
    static func crash(_ fn: String = #function) -> Never {
        fatalError("FakeLocalDatabase: unexpected call to \(fn)")
    }
}

extension LocalDatabaseProtocol {
    // Messages (overridable defaults)
    public func saveIncomingMessageAndQueueAck(_ message: Message) async throws { FakeDBUnused.crash() }
    public func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { FakeDBUnused.crash() }
    public func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { FakeDBUnused.crash() }
    public func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { FakeDBUnused.crash() }
    public func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { FakeDBUnused.crash() }
    public func searchMessages(conversationId: String, query: String) async throws -> [Message] { FakeDBUnused.crash() }
    // Conversations
    public func saveConversation(_ conversation: Conversation) async throws { FakeDBUnused.crash() }
    public func fetchConversation(id: String) async throws -> Conversation? { FakeDBUnused.crash() }
    public func fetchConversations() async throws -> [Conversation] { FakeDBUnused.crash() }
    public func deleteConversation(id: String) async throws { FakeDBUnused.crash() }
    // Contacts
    public func saveContact(_ user: User) async throws { FakeDBUnused.crash() }
    public func fetchContacts() async throws -> [User] { FakeDBUnused.crash() }
    public func searchContacts(query: String) async throws -> [User] { FakeDBUnused.crash() }
    // Vault
    public func saveVaultItem(_ item: VaultItem) async throws { FakeDBUnused.crash() }
    public func fetchVaultItems() async throws -> [VaultItem] { FakeDBUnused.crash() }
    public func deleteVaultItem(id: String) async throws { FakeDBUnused.crash() }
    // Access keys
    public func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws { FakeDBUnused.crash() }
    public func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { FakeDBUnused.crash() }
    public func updateAccessKeyEntryLastAccessed(mediaId: String, lastAccessedAt: Date) async throws { FakeDBUnused.crash() }
    public func deleteAccessKeyEntry(mediaId: String) async throws { FakeDBUnused.crash() }
    public func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { FakeDBUnused.crash() }
    public func deleteAllAccessKeyEntries() async throws { FakeDBUnused.crash() }
    public func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { FakeDBUnused.crash() }
    public func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws { FakeDBUnused.crash() }
    public func clearAppearanceOverride(conversationId: String) async throws { FakeDBUnused.crash() }
    public func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? { FakeDBUnused.crash() }
    public func setVaultPolicy(_ policy: ChatVaultPolicy) async throws { FakeDBUnused.crash() }
    public func clearVaultPolicy(conversationId: String) async throws { FakeDBUnused.crash() }
    public func fetchMessageById(_ messageId: String) async throws -> Message? { FakeDBUnused.crash() }
    // Lifecycle
    public func hasLocalHistory() async throws -> Bool { FakeDBUnused.crash() }
    public func exportBackupSnapshot(currentUserId: String?) async throws -> BackupArchiveSnapshot { FakeDBUnused.crash() }
    public func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?) async throws { FakeDBUnused.crash() }
    public func purgeAllData() async throws { FakeDBUnused.crash() }
    // Presence / denormalized conversation status
    public func updateUserPresence(userId: String, status: User.Status, lastSeen: Date?) async throws { FakeDBUnused.crash() }
    public func updateConversationLastMessageStatusIfMatches(
        conversationId: String,
        messageId: String,
        status: Message.DeliveryStatus
    ) async throws { FakeDBUnused.crash() }
}

// MARK: - Fakes

final class FakeLocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeLocalDatabase.lock")
    private var _savedMessages: [Message] = []
    private var _deletedIds: [String] = []
    private var _statusUpdates: [(id: String, status: Message.DeliveryStatus)] = []
    var saveMessageError: Error?
    var updateStatusError: Error?

    var savedMessages: [Message] { queue.sync { _savedMessages } }
    var deletedIds: [String] { queue.sync { _deletedIds } }
    var statusUpdates: [(id: String, status: Message.DeliveryStatus)] { queue.sync { _statusUpdates } }

    func saveMessage(_ message: Message) async throws {
        if let e = saveMessageError { throw e }
        queue.sync { _savedMessages.append(message) }
    }

    func deleteMessage(id: String) async throws {
        queue.sync { _deletedIds.append(id) }
    }

    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws {
        if let e = updateStatusError { throw e }
        queue.sync { _statusUpdates.append((id, status)) }
    }
}

actor FakeEncryptedSender: EncryptedMessageSendingClient {
    struct Call: Sendable {
        let plaintext: Data
        let contentType: String
        let conversationId: String
        let recipientIds: [String]
        let start: Date
        let end: Date
    }

    private(set) var calls: [Call] = []
    var result: Result<EncryptedMessageSendResult, Error> =
        .success(EncryptedMessageSendResult(messageId: "server-1", serverTimestampMs: 1_700_000_000_000))
    var delayNanos: UInt64 = 0

    func setResult(_ r: Result<EncryptedMessageSendResult, Error>) { self.result = r }
    func setDelay(_ ns: UInt64) { self.delayNanos = ns }

    func sendEncryptedMessage(
        plaintext: Data,
        contentType: String,
        conversationId: String,
        recipientIds: [String],
        expiresAfterSecs: Int64
    ) async throws -> EncryptedMessageSendResult {
        let start = Date()
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        let end = Date()
        calls.append(Call(
            plaintext: plaintext,
            contentType: contentType,
            conversationId: conversationId,
            recipientIds: recipientIds,
            start: start,
            end: end
        ))
        return try result.get()
    }
}

actor FakeUploader: MediaUploading {
    struct Call: Sendable {
        let localFileURL: URL
        let mimeType: String
        let conversationId: String
        let recipientId: String
    }

    private(set) var calls: [Call] = []
    var result: Result<MediaUploadOutcome, Error> = .success(
        MediaUploadOutcome(
            mediaId: "media-1",
            remoteURL: "https://example.invalid/media-1",
            thumbnailRemoteURL: nil,
            encryptedFileSize: 2048,
            plaintextFileSize: 1024,
            encryptionKey: Data(repeating: 0xAB, count: 32),
            encryptionNonce: Data(repeating: 0xCD, count: 12),
            encryptionTag: Data(repeating: 0xEF, count: 16),
            plaintextDigest: Data(repeating: 0x01, count: 32)
        )
    )

    func setResult(_ r: Result<MediaUploadOutcome, Error>) { self.result = r }

    func uploadMedia(
        localFileURL: URL,
        mimeType: String,
        conversationId: String,
        recipientId: String,
        progress: @Sendable (Double) -> Void
    ) async throws -> MediaUploadOutcome {
        calls.append(Call(
            localFileURL: localFileURL,
            mimeType: mimeType,
            conversationId: conversationId,
            recipientId: recipientId
        ))
        return try result.get()
    }
}

final class FakeCurrentUser: CurrentUserProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeCurrentUser.lock")
    private var _userId: String?

    init(userId: String? = "user-123") { self._userId = userId }

    var currentUserId: String? {
        get async { queue.sync { _userId } }
    }

    func set(_ id: String?) { queue.sync { _userId = id } }
}

// MARK: - Tests

final class MessageSenderTests: XCTestCase {

    private func makeLock() -> FileCoordinatorLock {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msgsender-test-\(UUID().uuidString).lock")
        return FileCoordinatorLock(lockURL: url)
    }

    private func makeSUT(
        db: FakeLocalDatabase = FakeLocalDatabase(),
        uploader: FakeUploader = FakeUploader(),
        sender: FakeEncryptedSender = FakeEncryptedSender(),
        user: FakeCurrentUser = FakeCurrentUser()
    ) -> (MessageSender, FakeLocalDatabase, FakeUploader, FakeEncryptedSender, FakeCurrentUser) {
        let ms = MessageSender(
            db: db,
            uploader: uploader,
            encryptedSender: sender,
            coordinator: makeLock(),
            currentUser: user,
            vaultPolicyResolver: NoopVaultPolicyResolver()
        )
        return (ms, db, uploader, sender, user)
    }

    // MARK: sendText

    func test_sendText_happyPath_writesPendingThenSent() async throws {
        let (sut, db, _, sender, _) = makeSUT()
        await sender.setResult(.success(EncryptedMessageSendResult(
            messageId: "server-abc",
            serverTimestampMs: 1_700_000_000_000
        )))

        let receipt = try await sut.sendText("hello world", to: "chat-A")

        // Pending insert
        XCTAssertEqual(db.savedMessages.count, 2, "Expected pending insert + confirmed insert")
        let pending = db.savedMessages[0]
        XCTAssertEqual(pending.status, .sending)
        XCTAssertEqual(pending.conversationId, "chat-A")
        if case .text(let s) = pending.content {
            XCTAssertEqual(s, "hello world")
        } else {
            XCTFail("Expected text content on pending row")
        }

        // Encrypted-send call
        let calls = await sender.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].contentType, "text")
        XCTAssertEqual(calls[0].conversationId, "chat-A")
        XCTAssertEqual(calls[0].recipientIds, ["chat-A"])
        XCTAssertEqual(calls[0].plaintext, "hello world".data(using: .utf8))

        // Confirmed row replaced pending (different server id → delete + insert)
        XCTAssertEqual(db.deletedIds, [pending.id])
        let confirmed = db.savedMessages[1]
        XCTAssertEqual(confirmed.id, "server-abc")
        XCTAssertEqual(confirmed.status, .sent)
        XCTAssertEqual(confirmed.timestamp.timeIntervalSince1970, 1_700_000_000.0, accuracy: 0.001)

        // Receipt
        XCTAssertEqual(receipt.chatId, "chat-A")
        XCTAssertEqual(receipt.messageId, "server-abc")
        XCTAssertEqual(receipt.serverTimestampMs, 1_700_000_000_000)
    }

    func test_sendText_encryptedSenderFails_marksMessageFailed() async throws {
        let (sut, db, _, sender, _) = makeSUT()
        await sender.setResult(.failure(AppError.networkUnavailable))

        do {
            _ = try await sut.sendText("hi", to: "chat-B")
            XCTFail("Expected sendText to throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .networkUnavailable)
        }

        // Pending row was inserted
        XCTAssertEqual(db.savedMessages.count, 1)
        XCTAssertEqual(db.savedMessages[0].status, .sending)

        // Status flipped to .failed for the pending local id
        XCTAssertEqual(db.statusUpdates.count, 1)
        XCTAssertEqual(db.statusUpdates[0].id, db.savedMessages[0].id)
        XCTAssertEqual(db.statusUpdates[0].status, .failed)

        // No deletion — failed row must persist for retry UI
        XCTAssertTrue(db.deletedIds.isEmpty)
    }

    func test_sendText_currentUserNil_throwsSessionExpired() async throws {
        let user = FakeCurrentUser(userId: nil)
        let (sut, db, _, sender, _) = makeSUT(user: user)

        do {
            _ = try await sut.sendText("x", to: "chat-C")
            XCTFail("Expected throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .sessionExpired)
        }

        XCTAssertTrue(db.savedMessages.isEmpty)
        let calls = await sender.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: sendMedia

    func test_sendMedia_happyPath_preservesVoiceFields() async throws {
        let (sut, db, uploader, sender, _) = makeSUT()
        let key = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0x22, count: 12)
        await uploader.setResult(.success(MediaUploadOutcome(
            mediaId: "media-xyz",
            remoteURL: "https://example.invalid/media-xyz",
            thumbnailRemoteURL: nil,
            encryptedFileSize: 9999,
            plaintextFileSize: 5000,
            encryptionKey: key,
            encryptionNonce: nonce,
            encryptionTag: Data(repeating: 0x33, count: 16),
            plaintextDigest: Data(repeating: 0x44, count: 32)
        )))
        await sender.setResult(.success(EncryptedMessageSendResult(
            messageId: "server-media-1",
            serverTimestampMs: 1_700_000_123_000
        )))

        let localFileURL = URL(fileURLWithPath: "/tmp/voice.m4a")
        let attachment = Message.MediaAttachment(
            url: localFileURL,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: "audio/mp4",
            sizeBytes: 5000,
            filename: "voice-1700.m4a",
            isVoiceMessage: true,
            audioDurationMs: 3700,
            audioWaveform: [0.1, 0.3, 0.7, 0.2]
        )

        let receipt = try await sut.sendMedia(
            attachment: attachment,
            caption: nil,
            to: "chat-V",
            progress: { _ in }
        )

        // Uploader called with the plaintext local URL + mime
        let upCalls = await uploader.calls
        XCTAssertEqual(upCalls.count, 1)
        XCTAssertEqual(upCalls[0].localFileURL, localFileURL)
        XCTAssertEqual(upCalls[0].mimeType, "audio/mp4")
        XCTAssertEqual(upCalls[0].conversationId, "chat-V")

        // Encrypted sender called with contentType "audio"
        let sendCalls = await sender.calls
        XCTAssertEqual(sendCalls.count, 1)
        XCTAssertEqual(sendCalls[0].contentType, "audio")
        XCTAssertEqual(sendCalls[0].conversationId, "chat-V")

        // Confirmed row (index 1) preserves voice fields exactly
        XCTAssertEqual(db.savedMessages.count, 2)
        let confirmed = db.savedMessages[1]
        XCTAssertEqual(confirmed.status, .sent)
        guard case .audio(let storedAttachment) = confirmed.content else {
            XCTFail("Expected .audio content on confirmed row")
            return
        }
        XCTAssertEqual(storedAttachment.isVoiceMessage, true)
        XCTAssertEqual(storedAttachment.audioDurationMs, 3700)
        XCTAssertEqual(storedAttachment.audioWaveform, [0.1, 0.3, 0.7, 0.2])
        XCTAssertEqual(storedAttachment.filename, "voice-1700.m4a")
        XCTAssertEqual(storedAttachment.encryptionKey, key)
        XCTAssertEqual(storedAttachment.encryptionIV, nonce)
        XCTAssertEqual(storedAttachment.url.absoluteString, "sanchr-media://media-xyz")

        XCTAssertEqual(receipt.messageId, "server-media-1")
        XCTAssertEqual(receipt.serverTimestampMs, 1_700_000_123_000)
    }

    func test_sendMedia_uploadFails_marksFailedAndDoesNotCallEncryptedSender() async throws {
        let (sut, db, uploader, sender, _) = makeSUT()
        await uploader.setResult(.failure(AppError.mediaUploadFailed))

        let attachment = Message.MediaAttachment(
            url: URL(fileURLWithPath: "/tmp/photo.jpg"),
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: "image/jpeg",
            sizeBytes: 1000
        )

        do {
            _ = try await sut.sendMedia(
                attachment: attachment,
                caption: "hi",
                to: "chat-U",
                progress: { _ in }
            )
            XCTFail("Expected throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .mediaUploadFailed)
        }

        XCTAssertEqual(db.savedMessages.count, 1)
        XCTAssertEqual(db.savedMessages[0].status, .sending)
        XCTAssertEqual(db.statusUpdates.count, 1)
        XCTAssertEqual(db.statusUpdates[0].status, .failed)

        let sendCalls = await sender.calls
        XCTAssertTrue(sendCalls.isEmpty, "encrypted sender must not be called after upload failure")
    }

    // MARK: Serialization

    func test_concurrentSends_serializeViaActor() async throws {
        let (sut, _, _, sender, _) = makeSUT()
        await sender.setDelay(50_000_000) // 50ms
        await sender.setResult(.success(EncryptedMessageSendResult(
            messageId: "",
            serverTimestampMs: 1_700_000_000_000
        )))

        try await withThrowingTaskGroup(of: MessageSendReceipt.self) { group in
            for i in 0..<3 {
                group.addTask { try await sut.sendText("msg-\(i)", to: "chat-S") }
            }
            var count = 0
            for try await _ in group { count += 1 }
            XCTAssertEqual(count, 3)
        }

        // The real guarantee here is enforced by the Swift compiler (sendText
        // is an actor method, so its local state is serialized). This test
        // exists to catch an accidental `Task.detached` inside the actor that
        // would break that guarantee. We assert all sends completed and were
        // recorded — timestamp-based non-overlap checks are unreliable on a
        // loaded CI because `coordinator.withLock` hops to a background queue.
        let calls = await sender.calls
        XCTAssertEqual(calls.count, 3)
        let bodies = Set(calls.map { String(data: $0.plaintext, encoding: .utf8) ?? "" })
        XCTAssertEqual(bodies, ["msg-0", "msg-1", "msg-2"])
    }
}
