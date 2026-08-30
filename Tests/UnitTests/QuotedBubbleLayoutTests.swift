import CoreGraphics
import XCTest

@testable import Sanchr

/// How wide a bubble carrying a quoted reply should be.
///
/// Every reply used to come out at the maximum width, whatever it said — a
/// one-word "Yes" quoting "Ok" was as wide as a full sentence — because the
/// quote card claimed all the width on offer in order to span the bubble, and
/// that claim was also what told the stack how wide to be.
final class QuotedBubbleLayoutTests: XCTestCase {

    private let cap: CGFloat = 300

    private func width(_ naturals: [CGFloat], quoted: Bool = true) -> CGFloat {
        QuotedBubbleLayout.resolvedWidth(
            naturalWidths: naturals,
            cap: cap,
            carriesQuote: quoted
        )
    }

    /// The regression: two replies with different content should not come out
    /// the same width.
    func testTwoRepliesOfDifferentLengthsGetDifferentWidths() {
        let short = width([60, 55])
        let long = width([280, 90])
        XCTAssertNotEqual(short, long)
        XCTAssertLessThan(short, long)
    }

    /// The bubble follows whichever part is wider — a short message under a
    /// long quote is as wide as the quote, and the reverse.
    func testTheWiderPartDecides() {
        XCTAssertEqual(width([40, 250]), 250)
        XCTAssertEqual(width([250, 40]), 250)
    }

    func testNothingExceedsTheCap() {
        XCTAssertEqual(width([9_000, 40]), cap)
    }

    /// Hugging alone leaves the quote as a couple of truncated words in a
    /// sliver, which stops it doing the one job it has.
    func testAQuotedBubbleIsNeverNarrowerThanItsFloor() {
        XCTAssertEqual(width([20, 20]), cap * 0.45)
    }

    /// A message with no quote keeps hugging — there is nothing there that
    /// becomes unreadable when narrow, and widening it would leave "Ok"
    /// stranded in a bubble half the screen wide.
    func testAMessageWithoutAQuoteStillHugs() {
        XCTAssertEqual(width([20], quoted: false), 20)
    }

    /// Measurement passes propose an unbounded width; a floor derived from it
    /// would be infinite.
    func testAnUnboundedProposalDoesNotProduceAnInfiniteFloor() {
        let measured = QuotedBubbleLayout.resolvedWidth(
            naturalWidths: [120, 80],
            cap: .infinity,
            carriesQuote: true
        )
        XCTAssertEqual(measured, 120)
    }
}
