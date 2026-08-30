import CoreGraphics
import XCTest
import SanchrShared

@testable import Sanchr

/// The long-press menu: which actions a message offers, and where the pieces
/// go on screen.
final class MessageContextMenuTests: XCTestCase {

    // MARK: - Actions

    func testEveryMessageCanBeRepliedToAndForwarded() {
        let actions = MessageContextAction.actions(
            isOutgoing: false, isSaveableMedia: false, canRetry: false, isText: true
        )
        XCTAssertEqual(Array(actions.prefix(2)), [.reply, .forward])
    }

    /// Copy appears once whatever it copies. Text and media each used to add
    /// their own, so anything that was both listed it twice — which a render
    /// of the menu showed immediately and no amount of reading would have.
    func testCopyIsOfferedOnlyOnce() {
        let actions = MessageContextAction.actions(
            isOutgoing: true, isSaveableMedia: true, canRetry: false, isText: true
        )
        XCTAssertEqual(actions.filter { $0 == .copy }.count, 1)
    }

    func testMediaOffersSavingAndSharing() {
        let actions = MessageContextAction.actions(
            isOutgoing: false, isSaveableMedia: true, canRetry: false, isText: false
        )
        XCTAssertTrue(actions.contains(.saveToPhotos))
        XCTAssertTrue(actions.contains(.share))
    }

    func testPlainTextOffersNeither() {
        let actions = MessageContextAction.actions(
            isOutgoing: false, isSaveableMedia: false, canRetry: false, isText: true
        )
        XCTAssertFalse(actions.contains(.saveToPhotos))
        XCTAssertFalse(actions.contains(.share))
    }

    /// Only your own messages can be deleted.
    func testDeleteIsOnlyOfferedOnYourOwnMessages() {
        XCTAssertTrue(
            MessageContextAction.actions(
                isOutgoing: true, isSaveableMedia: false, canRetry: false, isText: true
            ).contains(.delete)
        )
        XCTAssertFalse(
            MessageContextAction.actions(
                isOutgoing: false, isSaveableMedia: false, canRetry: false, isText: true
            ).contains(.delete)
        )
    }

    /// Destructive last, and never next to Reply — a Delete beside the action
    /// people reach for most is a Delete pressed by accident.
    func testDeleteIsLastAndNotAdjacentToReply() {
        let actions = MessageContextAction.actions(
            isOutgoing: true, isSaveableMedia: true, canRetry: false, isText: false
        )
        XCTAssertEqual(actions.last, .delete)
        XCTAssertGreaterThan(
            actions.firstIndex(of: .delete)! - actions.firstIndex(of: .reply)!, 1
        )
    }

    func testRetryOnlyAppearsForAFailedSend() {
        XCTAssertTrue(
            MessageContextAction.actions(
                isOutgoing: true, isSaveableMedia: false, canRetry: true, isText: true
            ).contains(.retry)
        )
        XCTAssertFalse(
            MessageContextAction.actions(
                isOutgoing: true, isSaveableMedia: false, canRetry: false, isText: true
            ).contains(.retry)
        )
    }

    // MARK: - Layout

    private let screen = CGRect(x: 0, y: 60, width: 390, height: 700)

    /// A message with room on both sides does not move. The point of the
    /// gesture is that the thing you pressed stays where you pressed it.
    func testAMessageWithRoomStaysPut() {
        let result = MessageContextMenuLayout.resolve(
            messageFrame: CGRect(x: 12, y: 350, width: 220, height: 44),
            reactionBarHeight: 52,
            menuHeight: 200,
            safeArea: screen
        )
        XCTAssertEqual(result.verticalOffset, 0)
        XCTAssertFalse(result.isScrollRequired)
    }

    /// Near the top there is no room for the bar above, so the group comes
    /// down. Without this the reaction bar is cut off by the screen edge —
    /// which is exactly what the first render showed.
    func testAMessageNearTheTopIsPushedDown() {
        let result = MessageContextMenuLayout.resolve(
            messageFrame: CGRect(x: 12, y: 70, width: 220, height: 44),
            reactionBarHeight: 52,
            menuHeight: 200,
            safeArea: screen
        )
        XCTAssertGreaterThan(result.verticalOffset, 0)
    }

    func testAMessageNearTheBottomIsPulledUp() {
        let result = MessageContextMenuLayout.resolve(
            messageFrame: CGRect(x: 12, y: 700, width: 220, height: 44),
            reactionBarHeight: 52,
            menuHeight: 200,
            safeArea: screen
        )
        XCTAssertLessThan(result.verticalOffset, 0)
    }

    /// A very tall message plus both accessories cannot fit. The message wins
    /// and the menu scrolls: sliding up until the menu fits would push the
    /// message off the top, losing the thing being acted on.
    func testAGroupTallerThanTheScreenAnchorsTheMessageAndScrollsTheMenu() {
        let result = MessageContextMenuLayout.resolve(
            messageFrame: CGRect(x: 12, y: 100, width: 220, height: 560),
            reactionBarHeight: 52,
            menuHeight: 300,
            safeArea: screen
        )
        XCTAssertTrue(result.isScrollRequired)
    }

    /// Whatever the offset, the reaction bar must end up on screen.
    func testTheReactionBarIsAlwaysOnScreen() {
        for y in stride(from: CGFloat(60), through: 740, by: 40) {
            let frame = CGRect(x: 12, y: y, width: 220, height: 44)
            let result = MessageContextMenuLayout.resolve(
                messageFrame: frame,
                reactionBarHeight: 52,
                menuHeight: 200,
                safeArea: screen
            )
            let barTop = frame.minY - 52 - MessageContextMenuLayout.spacing + result.verticalOffset
            XCTAssertGreaterThanOrEqual(
                barTop, screen.minY - 0.5,
                "the reaction bar is off the top for a message at y=\(y)"
            )
        }
    }
}
