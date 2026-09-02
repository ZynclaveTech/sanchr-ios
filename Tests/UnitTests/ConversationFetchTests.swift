import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// The conversation list is fetched several times before the user touches
/// it, and each fetch used to run two queries per conversation.
final class ConversationFetchTests: XCTestCase {

    func testTheListIsBuiltFromThreeQueriesNotTwoPerRow() throws {
        let db = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("SanchrShared/Persistence/LocalDatabase.swift"),
            encoding: .utf8
        )
        let fn = try XCTUnwrap(db.range(of: "private func fetchConversationRecords(includeHidden: Bool) async throws -> [Conversation] {"))
        let body = String(db[fn.upperBound...].prefix(2000))
        XCTAssertTrue(body.contains("conversationIds.contains(Column(\"conversationId\"))"))
        XCTAssertTrue(body.contains("userIds.contains(Column(\"id\"))"))
        // No per-row query inside the map.
        let map = try XCTUnwrap(body.range(of: "return conversationRecords.map { convRecord in"))
        let mapBody = String(body[map.upperBound...].prefix(300))
        XCTAssertFalse(mapBody.contains(".fetchAll(db)"))
    }

    /// Participants keep their order and every conversation keeps its own.
    func testParticipantsStayWithTheirConversation() async throws {
        let database = try LocalDatabase(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("conv-fetch-\(UUID().uuidString).sqlite"),
            passphraseProvider: { "unit-test-passphrase" }
        )
        func user(_ id: String) -> User {
            User(id: id, phoneNumber: "", displayName: id.capitalized, isVerified: false, status: .offline)
        }
        func conversation(_ id: String, _ users: [User]) -> Conversation {
            Conversation(id: id, participants: users, unreadCount: 0, isPinned: false, isMuted: false,
                         isArchived: false, type: .group, createdAt: Date(), updatedAt: Date())
        }
        try await database.saveConversation(conversation("a", [user("asha"), user("ravi")]))
        try await database.saveConversation(conversation("b", [user("ravi"), user("meera")]))

        let fetched = try await database.fetchConversations()
        let byId = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, Set($0.participants.map(\.id))) })
        XCTAssertEqual(byId["a"], ["asha", "ravi"])
        XCTAssertEqual(byId["b"], ["ravi", "meera"])
    }
}
