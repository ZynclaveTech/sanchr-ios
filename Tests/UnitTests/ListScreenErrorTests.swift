import Foundation
import XCTest

@testable import Sanchr

/// Failures on the chat lists must stay local to the action that failed.
final class ListScreenErrorTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// A failed unarchive/restore set `loadError`, which swaps the whole
    /// list for the "couldn't load" screen.
    func testAFailedRowActionDoesNotReplaceTheList() throws {
        for (file, remover) in [
            ("Features/Chats/Presentation/ArchivedChatsView.swift", "isUpdatingConversationIds.remove(conversationId)"),
            ("Features/Chats/Presentation/HiddenChatsView.swift", "isRestoringConversationIds.remove(conversationId)"),
        ] {
            let view = try source(file)
            let removal = try XCTUnwrap(view.range(of: remover, options: .backwards))
            let before = String(view[..<removal.lowerBound].suffix(120))
            XCTAssertTrue(before.contains("actionError = error.localizedDescription"), file)
            XCTAssertFalse(before.contains("loadError = error.localizedDescription"), file)
            XCTAssertTrue(view.contains("get: { actionError != nil }"), file)
        }
    }

    func testReturningToTheListReTracksPresence() throws {
        let view = try source("Features/Chats/Presentation/ChatsListView.swift")
        // The onAppear that syncs the Sanchr Mode chip is the one that runs
        // when a pushed chat is popped.
        let sync = try XCTUnwrap(view.range(of: "sanchrModeEnabled = container.privacySettings.sanchrModeEnabled"))
        XCTAssertTrue(String(view[sync.upperBound...].prefix(400)).contains("updatePresenceTrackingForVisibleConversations()"))
    }

    func testTheSanchrModeChipExplainsAFailure() throws {
        let view = try source("Features/Chats/Presentation/ChatsListView.swift")
        XCTAssertTrue(view.contains("sanchrModeChipError = error.localizedDescription"))
        XCTAssertTrue(view.contains(".alert(\"Couldn't change Sanchr Mode\""))
    }
}
