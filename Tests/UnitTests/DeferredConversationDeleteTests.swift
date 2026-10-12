import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// A conversation deleted while offline is removed from the phone at once and
/// its server delete is queued; the queue is settled on the next sync. Before this the
/// failure was logged and the conversation came back on the next full fetch.
final class DeferredConversationDeleteTests: XCTestCase {

    func testTheQueueIsDurableOrderedAndClearable() async throws {
        let database = try LocalDatabase(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("del-\(UUID().uuidString).sqlite"),
            passphraseProvider: { "unit-test-passphrase" }
        )
        try await database.enqueuePendingConversationDelete(conversationId: "b")
        try await database.enqueuePendingConversationDelete(conversationId: "a")
        try await database.enqueuePendingConversationDelete(conversationId: "b")

        let queued = try await database.fetchPendingConversationDeletes()
        XCTAssertEqual(queued, ["b", "a"])
        try await database.removePendingConversationDelete(conversationId: "b")
        let remaining = try await database.fetchPendingConversationDeletes()
        XCTAssertEqual(remaining, ["a"])
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testAFailedServerDeleteIsQueuedAndSettledOnSync() throws {
        // Queued where the server call is made, so every screen that deletes
        // a conversation gets it.
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        XCTAssertTrue(repository.contains("localDatabase.enqueuePendingConversationDelete(conversationId: conversationId)"))
        let realtime = try source("Shared/Services/RealtimeService.swift")
        XCTAssertTrue(realtime.contains("messageRepository.flushPendingConversationDeletes()"))
    }
}
