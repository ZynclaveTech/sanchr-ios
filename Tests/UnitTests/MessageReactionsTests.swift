import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Reactions, as they appear on a message.
///
/// They could be chosen, were stored, were sent, and the cell's render
/// signature even tracked them so it would reconfigure when they changed — and
/// no view in the app referenced `Message.reactions` at all. Picking one from
/// the context menu appeared to do nothing, because nothing drew it.
final class MessageReactionsTests: XCTestCase {

    private func reaction(_ emoji: String, _ user: String, _ offset: TimeInterval) -> Message.MessageReaction {
        Message.MessageReaction(
            emoji: emoji,
            userId: user,
            timestamp: Date(timeIntervalSince1970: 1_000 + offset)
        )
    }

    // MARK: - Grouping

    func testTheSameEmojiFromSeveralPeopleIsOneEntry() {
        let grouped = MessageReactionsPill.grouped([
            reaction("👍", "a", 0),
            reaction("👍", "b", 1),
            reaction("👍", "c", 2)
        ])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].emoji, "👍")
        XCTAssertEqual(grouped[0].count, 3)
    }

    /// Ordered by first use, not by count. A pill that reorders as reactions
    /// arrive moves the one you were reaching for out from under your thumb.
    func testEntriesKeepTheOrderTheyWereFirstUsedIn() {
        let grouped = MessageReactionsPill.grouped([
            reaction("🙏", "a", 0),
            reaction("😂", "b", 1),
            reaction("😂", "c", 2),
            reaction("😂", "d", 3),
            reaction("❤️", "e", 4)
        ])
        XCTAssertEqual(grouped.map(\.emoji), ["🙏", "😂", "❤️"])
        XCTAssertEqual(grouped.map(\.count), [1, 3, 1])
    }

    /// Order comes from the timestamps, not from the order they happen to be
    /// stored in — a reaction that syncs late is still an old reaction.
    func testOrderFollowsTheTimestamps() {
        let grouped = MessageReactionsPill.grouped([
            reaction("❤️", "late", 9),
            reaction("👍", "early", 1)
        ])
        XCTAssertEqual(grouped.map(\.emoji), ["👍", "❤️"])
    }

    func testNoReactionsGroupToNothing() {
        XCTAssertTrue(MessageReactionsPill.grouped([]).isEmpty)
    }

    // MARK: - Wiring

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

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The bubble is what has to draw them. Storing, sending and tracking them
    /// was never the missing part.
    func testTheBubbleDrawsReactions() throws {
        let body = code(try source("Features/Chats/Presentation/MessageBubble.swift"))
        XCTAssertTrue(body.contains("MessageReactionsPill("))
        XCTAssertTrue(body.contains("if !message.reactions.isEmpty {"))
    }

    /// An overlay adds no height, so the pill would otherwise hang over the
    /// timestamp and the message below it.
    func testTheBubbleReservesRoomForThePill() throws {
        let body = code(try source("Features/Chats/Presentation/MessageBubble.swift"))
        XCTAssertTrue(
            body.contains("padding(.bottom, message.reactions.isEmpty ? 0 : Self.reactionOverhang * 2)")
        )
    }

    /// Tapping a reaction toggles yours, which is the same call the context
    /// menu makes.
    func testThePillTogglesThroughTheSamePathAsTheMenu() throws {
        let body = code(try source("Features/Chats/Presentation/ChatDetailView.swift"))
        XCTAssertTrue(body.contains("onToggleReaction: { messageId, emoji in"))
        XCTAssertTrue(body.contains("viewModel.toggleReaction("))
    }

    /// Exactly one thing draws reactions.
    ///
    /// A detached row already existed inside the collection view controller,
    /// below the bubble and aligned to the far edge. Adding the attached pill
    /// without removing it drew every reaction twice — once on the bubble and
    /// once floating beneath it.
    func testReactionsAreDrawnOnce() throws {
        let controller = code(
            try source("Features/Chats/Presentation/MessageCollectionViewController.swift")
        )
        XCTAssertFalse(
            controller.contains("ReactionPillsRow"),
            "the cell must not draw its own row alongside the bubble's pill"
        )
    }
}
