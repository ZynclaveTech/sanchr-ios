import Foundation
import XCTest
import SanchrShared

/// Unsent composer text, kept per conversation.
///
/// There were no drafts at all: leaving a chat mid-sentence threw the text
/// away with no warning and no way back.
final class DraftPersistenceTests: XCTestCase {

    private var db: LocalDatabase!
    private var conversationId: String!
    private var path: URL!

    override func setUp() async throws {
        try await super.setUp()
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drafts-\(UUID().uuidString).sqlite")
        db = try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
        conversationId = "conv-\(UUID().uuidString)"
        try await db.saveConversation(
            Conversation(
                id: conversationId,
                participants: [],
                unreadCount: 0,
                isPinned: false,
                isMuted: false,
                isArchived: false,
                type: .oneToOne,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    override func tearDown() async throws {
        db = nil
        if let path { try? FileManager.default.removeItem(at: path) }
        try await super.tearDown()
    }

    func testADraftSurvivesAndIsReadBack() async throws {
        try await db.saveDraft(conversationId: conversationId, text: "half a thought")
        let draft = try await db.draft(conversationId: conversationId)
        XCTAssertEqual(draft, "half a thought")
    }

    func testNoDraftReadsAsNil() async throws {
        let draft = try await db.draft(conversationId: conversationId)
        XCTAssertNil(draft)
    }

    /// Sending clears the composer, so the stored draft has to go too —
    /// otherwise reopening the chat restores text already sent.
    func testClearingRemovesIt() async throws {
        try await db.saveDraft(conversationId: conversationId, text: "typed")
        try await db.saveDraft(conversationId: conversationId, text: nil)
        let draft = try await db.draft(conversationId: conversationId)
        XCTAssertNil(draft)
    }

    /// Whitespace is not a draft. Storing it would leave the chat list
    /// advertising one that looks empty when opened.
    func testWhitespaceIsNotADraft() async throws {
        try await db.saveDraft(conversationId: conversationId, text: "   \n ")
        let draft = try await db.draft(conversationId: conversationId)
        XCTAssertNil(draft)
    }

    /// Leading and trailing space inside a real draft is preserved — someone
    /// mid-sentence should get their cursor position back, not a trimmed line.
    func testRealDraftKeepsItsSpacing() async throws {
        try await db.saveDraft(conversationId: conversationId, text: "see you at ")
        let draft = try await db.draft(conversationId: conversationId)
        XCTAssertEqual(draft, "see you at ")
    }

    /// The trap this design has to avoid: a conversation refreshed from the
    /// server carries no draft, and anything that overwrote the row with the
    /// incoming value would delete what the user had half-written the moment
    /// something synced.
    func testASyncFromTheServerDoesNotEraseTheDraft() async throws {
        try await db.saveDraft(conversationId: conversationId, text: "don't lose me")

        try await db.saveConversation(
            Conversation(
                id: conversationId,
                participants: [],
                unreadCount: 3,
                isPinned: false,
                isMuted: false,
                isArchived: false,
                type: .oneToOne,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_009_999)
            )
        )

        let draft = try await db.draft(conversationId: conversationId)
        XCTAssertEqual(draft, "don't lose me", "a server refresh wiped the draft")
    }

    /// Drafts belong to one conversation each.
    func testDraftsDoNotLeakBetweenConversations() async throws {
        let other = "conv-\(UUID().uuidString)"
        try await db.saveConversation(
            Conversation(
                id: other, participants: [], unreadCount: 0,
                isPinned: false, isMuted: false, isArchived: false,
                type: .oneToOne,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        try await db.saveDraft(conversationId: conversationId, text: "for A")
        try await db.saveDraft(conversationId: other, text: "for B")

        let a = try await db.draft(conversationId: conversationId)
        let b = try await db.draft(conversationId: other)
        XCTAssertEqual(a, "for A")
        XCTAssertEqual(b, "for B")
    }

    /// A draft has to reach the chat list, which reads whole conversations
    /// rather than calling `draft(conversationId:)`.
    func testTheDraftIsCarriedOnTheFetchedConversation() async throws {
        try await db.saveDraft(conversationId: conversationId, text: "shown in the list")
        let conversations = try await db.fetchConversations()
        let match = conversations.first { $0.id == conversationId }
        XCTAssertEqual(match?.draftText, "shown in the list")
    }
}
