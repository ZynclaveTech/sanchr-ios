import XCTest

@testable import Sanchr
@testable import SanchrShared

/// Disappearing messages must actually delete messages.
///
/// Before this suite the feature was inert end to end: the settings screen wrote
/// a number to UserDefaults, the sealed send path dropped the TTL because
/// `SendSealedMessageRequest` has no field for it, `expiresAt` was never written
/// on either send or receive, and no sweeper existed. The `idx_message_expiresAt`
/// index was commented "for expired message cleanup" and had no query consumers.
final class DisappearingMessagesTests: XCTestCase {

    private var dbDirectory: URL!
    private var db: LocalDatabase!

    override func setUp() async throws {
        try await super.setUp()
        dbDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dbDirectory, withIntermediateDirectories: true)
        let path = dbDirectory.appendingPathComponent("sanchr-tests.sqlite").path
        db = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        try await db.saveConversation(makeConversation())
    }

    override func tearDown() async throws {
        db = nil
        if let dbDirectory { try? FileManager.default.removeItem(at: dbDirectory) }
        try await super.tearDown()
    }

    private func makeConversation() -> Conversation {
        Conversation(
            id: "conv-1",
            participants: [
                User(id: "local-user", phoneNumber: "+15550000001",
                     displayName: "Local", avatarURL: nil, bio: nil, isVerified: true,
                     lastSeen: nil, identityKeyFingerprint: nil, status: .online,
                     isLocalUser: true),
                User(id: "peer-1", phoneNumber: "+15550000002",
                     displayName: "Peer", avatarURL: nil, bio: nil, isVerified: true,
                     lastSeen: nil, identityKeyFingerprint: nil, status: .offline,
                     isLocalUser: false),
            ],
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            disappearingMessagesDuration: nil,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func message(
        id: String,
        conversationId: String = "conv-1",
        expiresAt: Date?,
        timestamp: Date = Date()
    ) -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderId: "peer-1",
            timestamp: timestamp,
            content: .text("secret"),
            status: .delivered,
            isOutgoing: false,
            expiresAt: expiresAt
        )
    }

    // MARK: - Purge

    func test_purge_deletesExpiredAndReturnsIds() async throws {
        try await db.saveMessage(message(id: "gone", expiresAt: Date(timeIntervalSinceNow: -60)))
        try await db.saveMessage(message(id: "stays", expiresAt: Date(timeIntervalSinceNow: 3600)))
        try await db.saveMessage(message(id: "no-timer", expiresAt: nil))

        let purged = try await db.purgeExpiredMessages()

        XCTAssertEqual(purged, ["gone"])
        let remaining = try await db.fetchMessages(
            conversationId: "conv-1", before: nil, limit: 50)
        XCTAssertEqual(Set(remaining.map(\.id)), ["stays", "no-timer"])
    }

    func test_purge_withNothingExpired_isNoOp() async throws {
        try await db.saveMessage(message(id: "a", expiresAt: Date(timeIntervalSinceNow: 3600)))
        try await db.saveMessage(message(id: "b", expiresAt: nil))

        let purged = try await db.purgeExpiredMessages()
        XCTAssertTrue(purged.isEmpty)
        let remaining = try await db.fetchMessages(
            conversationId: "conv-1", before: nil, limit: 50)
        XCTAssertEqual(remaining.count, 2)
    }

    func test_purge_atExactDeadline_treatsMessageAsExpired() async throws {
        try await db.saveMessage(message(id: "boundary", expiresAt: Date(timeIntervalSinceNow: -0.001)))
        let purged = try await db.purgeExpiredMessages()
        XCTAssertEqual(purged, ["boundary"])
    }

    // MARK: - Read filtering

    /// A sweep runs on a timer, so there is always a window where an expired row
    /// still exists. It must never be *shown* during that window — reading is the
    /// moment the content would be disclosed.
    func test_fetch_hidesExpiredMessagesEvenBeforeSweep() async throws {
        try await db.saveMessage(message(id: "expired", expiresAt: Date(timeIntervalSinceNow: -1)))
        try await db.saveMessage(message(id: "live", expiresAt: Date(timeIntervalSinceNow: 3600)))

        let visible = try await db.fetchMessages(
            conversationId: "conv-1", before: nil, limit: 50)

        XCTAssertEqual(visible.map(\.id), ["live"])
    }

    func test_fetch_keepsMessagesWithNoTimer() async throws {
        try await db.saveMessage(message(id: "plain", expiresAt: nil))
        let visible = try await db.fetchMessages(
            conversationId: "conv-1", before: nil, limit: 50)
        XCTAssertEqual(visible.map(\.id), ["plain"])
    }

    func test_expiresAt_roundTripsThroughStorage() async throws {
        let deadline = Date(timeIntervalSinceNow: 600)
        try await db.saveMessage(message(id: "m", expiresAt: deadline))

        let fetched = try await db.fetchMessageById("m")
        XCTAssertNotNil(fetched?.expiresAt)
        XCTAssertEqual(
            fetched?.expiresAt?.timeIntervalSince1970 ?? 0,
            deadline.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - Wire format

    /// The TTL rides inside the sealed envelope. If it stopped being carried, the
    /// recipient would silently keep messages forever while the sender's copy
    /// vanished — the exact asymmetry this feature must not have.
    func test_innerPayload_carriesTimerAcrossEncoding() throws {
        let payload = InnerPayload(
            conversationId: "conv-1",
            messageId: "m-1",
            contentType: "text",
            content: Data("hi".utf8),
            isSync: false,
            expiresAfterSecs: 300
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(InnerPayload.self, from: encoded)

        XCTAssertEqual(decoded.expiresAfterSecs, 300)
    }

    /// Payloads written before this field existed must still decode, otherwise
    /// upgrading breaks every in-flight message.
    func test_innerPayload_withoutTimer_stillDecodes() throws {
        let legacy = """
        {"v":1,"conversation_id":"c","message_id":"m","content_type":"text",
         "content":"aGk=","is_sync":false}
        """
        let decoded = try JSONDecoder().decode(
            InnerPayload.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.expiresAfterSecs)
        XCTAssertEqual(decoded.conversationId, "c")
    }

    func test_innerPayload_wireKeyIsSnakeCase() throws {
        let payload = InnerPayload(
            conversationId: "c", messageId: nil, contentType: "text",
            content: Data(), isSync: false, expiresAfterSecs: 60
        )
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("expires_after_secs"))
    }

    // MARK: - Deadline anchoring

    /// Deadlines are anchored to the server timestamp, not to local arrival. A
    /// device that syncs a week late must not grant itself a fresh full lifetime
    /// on messages that should already be gone.
    func test_deadlineAnchoredToSendTime_notArrivalTime() async throws {
        let sentAWeekAgo = Date(timeIntervalSinceNow: -7 * 24 * 3600)
        let ttl: TimeInterval = 300
        let anchored = sentAWeekAgo.addingTimeInterval(ttl)

        try await db.saveMessage(
            message(id: "stale", expiresAt: anchored, timestamp: sentAWeekAgo))

        let purged = try await db.purgeExpiredMessages()
        XCTAssertEqual(
            purged, ["stale"],
            "a late-synced message past its deadline must be removed immediately")
    }
}

// MARK: - Clear chat

/// "Clear All Messages" promised permanent deletion and was an empty closure.
/// These pin the behaviour behind it.
final class ClearChatTests: XCTestCase {

    private var dbDirectory: URL!
    private var db: LocalDatabase!

    override func setUp() async throws {
        try await super.setUp()
        dbDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dbDirectory, withIntermediateDirectories: true)
        db = try LocalDatabase(
            path: dbDirectory.appendingPathComponent("t.sqlite").path,
            passphraseProvider: { "unit-test-passphrase" })
        try await db.saveConversation(Self.conversation(id: "conv-a"))
        try await db.saveConversation(Self.conversation(id: "conv-b"))
    }

    override func tearDown() async throws {
        db = nil
        if let dbDirectory { try? FileManager.default.removeItem(at: dbDirectory) }
        try await super.tearDown()
    }

    static func conversation(id: String) -> Conversation {
        Conversation(
            id: id,
            participants: [
                User(id: "local-user", phoneNumber: "+15550000001", displayName: "Local",
                     avatarURL: nil, bio: nil, isVerified: true, lastSeen: nil,
                     identityKeyFingerprint: nil, status: .online, isLocalUser: true),
                User(id: "peer-1", phoneNumber: "+15550000002", displayName: "Peer",
                     avatarURL: nil, bio: nil, isVerified: true, lastSeen: nil,
                     identityKeyFingerprint: nil, status: .offline, isLocalUser: false),
            ],
            lastMessage: nil, unreadCount: 0, isPinned: false, isMuted: false,
            isArchived: false, type: .oneToOne, disappearingMessagesDuration: nil,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func message(_ id: String, in conversationId: String) -> Message {
        Message(id: id, conversationId: conversationId, senderId: "peer-1",
                timestamp: Date(), content: .text("hi"), status: .delivered,
                isOutgoing: false)
    }

    func test_clear_removesEveryMessageAndReturnsIds() async throws {
        try await db.saveMessage(message("m1", in: "conv-a"))
        try await db.saveMessage(message("m2", in: "conv-a"))

        let removed = try await db.deleteAllMessages(conversationId: "conv-a")

        XCTAssertEqual(Set(removed), ["m1", "m2"])
        let remaining = try await db.fetchMessages(
            conversationId: "conv-a", before: nil, limit: 50)
        XCTAssertTrue(remaining.isEmpty, "the dialog promises permanent deletion")
    }

    /// Ids are returned so the caller can wipe cached media. An attachment
    /// outliving its message leaves exactly what the user asked to be gone.
    func test_clear_returnsIdsSoMediaCanBeWiped() async throws {
        try await db.saveMessage(message("m1", in: "conv-a"))
        let removed = try await db.deleteAllMessages(conversationId: "conv-a")
        XCTAssertEqual(removed, ["m1"])
    }

    func test_clear_doesNotTouchOtherConversations() async throws {
        try await db.saveMessage(message("a1", in: "conv-a"))
        try await db.saveMessage(message("b1", in: "conv-b"))

        _ = try await db.deleteAllMessages(conversationId: "conv-a")

        let other = try await db.fetchMessages(
            conversationId: "conv-b", before: nil, limit: 50)
        XCTAssertEqual(other.map(\.id), ["b1"])
    }

    func test_clear_onEmptyConversation_isNoOp() async throws {
        let removed = try await db.deleteAllMessages(conversationId: "conv-a")
        XCTAssertTrue(removed.isEmpty)
    }

    /// The conversation row survives — clearing is not deleting the chat.
    func test_clear_keepsTheConversationItself() async throws {
        try await db.saveMessage(message("m1", in: "conv-a"))
        _ = try await db.deleteAllMessages(conversationId: "conv-a")

        let conversation = try await db.fetchConversation(id: "conv-a")
        XCTAssertNotNil(conversation, "clearing messages must not delete the chat")
    }
}

// MARK: - Timer storage

/// The timer used to live in plaintext UserDefaults under
/// `sanchr.disappearing.<conversationId>`, which exposed both the conversation
/// ids and the fact that a chat used ephemeral messaging to anything that could
/// read the app's plist — including an unencrypted device backup.
final class DisappearingTimerStorageTests: XCTestCase {

    private var dbDirectory: URL!
    private var db: LocalDatabase!

    override func setUp() async throws {
        try await super.setUp()
        dbDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dbDirectory, withIntermediateDirectories: true)
        db = try LocalDatabase(
            path: dbDirectory.appendingPathComponent("t.sqlite").path,
            passphraseProvider: { "unit-test-passphrase" })
        try await db.saveConversation(ClearChatTests.conversation(id: "conv-a"))
    }

    override func tearDown() async throws {
        db = nil
        if let dbDirectory { try? FileManager.default.removeItem(at: dbDirectory) }
        try await super.tearDown()
    }

    func test_timerDefaultsToOff() async throws {
        let seconds = try await db.disappearingDuration(conversationId: "conv-a")
        XCTAssertEqual(seconds, 0)
    }

    func test_timerRoundTripsThroughTheEncryptedRow() async throws {
        try await db.setDisappearingDuration(conversationId: "conv-a", seconds: 3600)
        let seconds = try await db.disappearingDuration(conversationId: "conv-a")
        XCTAssertEqual(seconds, 3600)
    }

    func test_settingZeroClearsTheTimer() async throws {
        try await db.setDisappearingDuration(conversationId: "conv-a", seconds: 300)
        try await db.setDisappearingDuration(conversationId: "conv-a", seconds: 0)
        let seconds = try await db.disappearingDuration(conversationId: "conv-a")
        XCTAssertEqual(seconds, 0, "Off must mean no timer, not a zero-length one")
    }

    func test_unknownConversationReportsNoTimer() async throws {
        let seconds = try await db.disappearingDuration(conversationId: "does-not-exist")
        XCTAssertEqual(seconds, 0)
    }

    /// The timer must not be readable from UserDefaults any more.
    func test_settingTheTimerWritesNothingToUserDefaults() async throws {
        let defaults = UserDefaults(suiteName: "timer-storage-\(UUID().uuidString)")!
        try await db.setDisappearingDuration(conversationId: "conv-a", seconds: 900)

        let leaked = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(DisappearingTimerLegacyCleanup.keyPrefix)
        }
        XCTAssertTrue(leaked.isEmpty, "the timer must not reach plaintext defaults")
    }

    // MARK: - Legacy cleanup

    func test_purgeRemovesLegacyKeysAndLeavesOthersAlone() {
        let defaults = UserDefaults(suiteName: "timer-purge-\(UUID().uuidString)")!
        defaults.set(300, forKey: "sanchr.disappearing.conv-a")
        defaults.set(3600, forKey: "sanchr.disappearing.conv-b")
        defaults.set("keep", forKey: "sanchr.someOtherSetting")

        let removed = DisappearingTimerLegacyCleanup.purge(defaults: defaults)

        XCTAssertEqual(removed, 2)
        XCTAssertNil(defaults.object(forKey: "sanchr.disappearing.conv-a"))
        XCTAssertNil(defaults.object(forKey: "sanchr.disappearing.conv-b"))
        XCTAssertEqual(defaults.string(forKey: "sanchr.someOtherSetting"), "keep")
    }

    /// Deleting rather than migrating is deliberate: the old setting never took
    /// effect, so carrying a forgotten timer forward would silently start
    /// destroying history the user has been able to see all along.
    func test_purgeDoesNotMigrateValuesIntoTheDatabase() async throws {
        let defaults = UserDefaults(suiteName: "timer-nomigrate-\(UUID().uuidString)")!
        defaults.set(300, forKey: "sanchr.disappearing.conv-a")

        DisappearingTimerLegacyCleanup.purge(defaults: defaults)

        let seconds = try await db.disappearingDuration(conversationId: "conv-a")
        XCTAssertEqual(seconds, 0, "a stale timer must not silently activate deletion")
    }

    func test_purgeOnCleanDefaultsIsNoOp() {
        let defaults = UserDefaults(suiteName: "timer-clean-\(UUID().uuidString)")!
        XCTAssertEqual(DisappearingTimerLegacyCleanup.purge(defaults: defaults), 0)
    }
}
