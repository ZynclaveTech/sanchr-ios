import XCTest
import SanchrShared

@testable import Sanchr

/// The quoted card that a reply carries.
///
/// It used to be drawn above the bubble on the transcript background, which
/// made a reply read as two loose objects rather than one message that answers
/// another. It now sits inside the bubble, following Signal's
/// `CVQuotedMessageView`: a stripe, a tint over the bubble's own fill, and the
/// author named above one line of what they said.
final class ReplyQuoteTests: XCTestCase {

    private func message(
        _ id: String,
        outgoing: Bool,
        text: String = "hello",
        replyTo: String? = nil
    ) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: outgoing ? "me" : "them",
            timestamp: Date(),
            content: .text(text),
            status: .sent,
            isOutgoing: outgoing,
            replyToMessageId: replyTo,
            expiresAt: nil
        )
    }

    private func index(_ messages: [Message]) -> [String: Message] {
        Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Attribution

    /// A quote says who is being quoted. Without it the card shows what was
    /// said but not who said it, which is half the reason to quote.
    func testTheQuoteNamesThePersonBeingQuoted() throws {
        let quoted = message("q", outgoing: false, text: "Are we on for six?")
        let reply = message("r", outgoing: true, replyTo: "q")

        let quote = try XCTUnwrap(
            MessageCollectionViewController.quote(
                for: reply,
                in: index([quoted, reply]),
                peerName: "Ravi"
            )
        )
        XCTAssertEqual(quote.authorName, "Ravi")
        XCTAssertEqual(quote.preview, "Are we on for six?")
        XCTAssertFalse(quote.quotedIsOutgoing)
    }

    /// Quoting yourself says "You" rather than your own name, the way every
    /// messenger does — the name would read as a third party.
    func testQuotingYourselfSaysYou() throws {
        let quoted = message("q", outgoing: true, text: "On my way")
        let reply = message("r", outgoing: false, replyTo: "q")

        let quote = try XCTUnwrap(
            MessageCollectionViewController.quote(
                for: reply,
                in: index([quoted, reply]),
                peerName: "Ravi"
            )
        )
        XCTAssertEqual(quote.authorName, "You")
        XCTAssertTrue(quote.quotedIsOutgoing)
    }

    /// A reply whose target is not loaded — older than the window, or deleted
    /// — resolves to nil, and the bubble falls back to saying only that it is
    /// a reply rather than inventing an author.
    func testAnUnresolvableQuoteIsNil() {
        let reply = message("r", outgoing: true, replyTo: "not-loaded")
        XCTAssertNil(
            MessageCollectionViewController.quote(
                for: reply,
                in: index([reply]),
                peerName: "Ravi"
            )
        )
    }

    func testAMessageThatIsNotAReplyHasNoQuote() {
        let plain = message("p", outgoing: true)
        XCTAssertNil(
            MessageCollectionViewController.quote(
                for: plain,
                in: index([plain]),
                peerName: "Ravi"
            )
        )
    }
}
