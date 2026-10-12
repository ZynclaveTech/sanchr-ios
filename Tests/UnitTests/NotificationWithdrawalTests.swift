import XCTest

@testable import Sanchr

/// A chat's delivered notifications come down when the chat is deleted,
/// hidden, cleared or read — not only when it is opened.
///
/// A notification can carry who wrote and a preview of what. Removed only on
/// opening the chat, it stayed on the lock screen after the chat it was
/// about had been deleted.
final class NotificationWithdrawalTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// The body of the function starting at `signature`, up to the next
    /// function at the same indentation.
    private func body(of signature: String, in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: signature), signature)
        let rest = source[start.upperBound...]
        let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    /// "]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return rest[..<(ends.min() ?? rest.endIndex)]
    }

    func testDeletingHidingAndReadingAChatEachWithdrawItsNotifications() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        for signature in [
            "func deleteConversation(conversationId: String) async throws {",
            "func hideConversationLocally(conversationId: String) async throws {",
            "func markAsRead(conversationId: String, upToMessageId: String) async throws {",
            "func markAsReadLocally(conversationId: String, upToMessageId: String) async throws {",
        ] {
            XCTAssertTrue(
                try body(of: signature, in: repository).contains("clearNotifications(conversationId)"),
                signature
            )
        }
    }

    /// Restoring a hidden chat removes nothing: there is nothing stale to
    /// take down, and a notification that arrived meanwhile is still news.
    func testRestoringAChatLeavesItsNotificationsAlone() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        let restore = try body(
            of: "func restoreConversationLocally(conversationId: String) async throws {", in: repository)

        XCTAssertFalse(restore.contains("clearNotifications("))
    }

    func testClearingAChatWithdrawsItsNotifications() throws {
        let info = try source("Features/Chats/Presentation/ConversationInfoView.swift")
        let clear = try body(of: "private func clearAllMessages() async {", in: info)

        XCTAssertTrue(clear.contains("SanchrNotificationService.clearNotifications(for: conversation.id)"))
    }

    /// The real thing by default: a repository built without saying
    /// otherwise must not quietly do nothing.
    func testTheRepositoryClearsRealNotificationsUnlessToldOtherwise() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")

        XCTAssertTrue(repository.contains("SanchrNotificationService.clearNotifications(for: $0)"))
    }
}
