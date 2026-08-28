import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Trimming the transcript window. The safety properties matter more than the
/// saving: this drops messages from a live conversation, so anything it
/// removes must be both re-fetchable and genuinely below the user's view.
@MainActor
final class TranscriptWindowTrimTests: XCTestCase {

    private func makeViewModel(messageCount: Int) -> ChatDetailViewModel {
        let vm = ChatDetailViewModel()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        vm.messages = (0..<messageCount).map { index in
            Message(
                id: "m\(index)",
                conversationId: "c",
                senderId: "s",
                timestamp: base.addingTimeInterval(TimeInterval(index * 60)),
                content: .text("m\(index)"),
                status: .sent,
                isOutgoing: false
            )
        }
        return vm
    }

    // MARK: - When it acts

    /// An ordinary conversation must never be touched.
    func testDoesNothingBelowTheThreshold() {
        let vm = makeViewModel(messageCount: 200)
        XCTAssertFalse(vm.trimToRecentWindowIfAtBottom(isAtBottom: true))
        XCTAssertEqual(vm.messages.count, 200)
    }

    /// Trimming away from the bottom would drop messages the user is looking
    /// at, or is about to scroll into.
    func testDoesNothingWhenNotAtTheBottom() {
        let vm = makeViewModel(messageCount: 1000)
        XCTAssertFalse(vm.trimToRecentWindowIfAtBottom(isAtBottom: false))
        XCTAssertEqual(vm.messages.count, 1000)
    }

    func testTrimsToTheWindowWhenAtTheBottom() {
        let vm = makeViewModel(messageCount: 1000)
        XCTAssertTrue(vm.trimToRecentWindowIfAtBottom(isAtBottom: true))
        XCTAssertEqual(vm.messages.count, ChatDetailViewModel.retainedWindowSize)
    }

    // MARK: - What it keeps

    /// The whole safety argument: only the oldest go. Dropping anything newer
    /// would lose messages with no way back, since paging only fetches older.
    func testKeepsTheNewestAndDropsOnlyTheOldest() {
        let vm = makeViewModel(messageCount: 1000)
        let newestBefore = vm.messages.suffix(ChatDetailViewModel.retainedWindowSize).map(\.id)

        vm.trimToRecentWindowIfAtBottom(isAtBottom: true)

        XCTAssertEqual(vm.messages.map(\.id), newestBefore)
        XCTAssertEqual(vm.messages.last?.id, "m999", "the newest message must survive")
    }

    func testOrderIsPreserved() {
        let vm = makeViewModel(messageCount: 1000)
        vm.trimToRecentWindowIfAtBottom(isAtBottom: true)
        let timestamps = vm.messages.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted(), "the window stays ascending")
    }

    // MARK: - State that must follow

    /// Older messages exist again by definition — they were just discarded —
    /// so paging up has to be re-armed or the user cannot get them back.
    func testPagingUpIsReArmed() {
        let vm = makeViewModel(messageCount: 1000)
        vm.hasMoreMessages = false
        vm.trimToRecentWindowIfAtBottom(isAtBottom: true)
        XCTAssertTrue(vm.hasMoreMessages)
    }

    /// A stale anchor would page from a message no longer loaded.
    func testPaginationAnchorIsCleared() {
        let vm = makeViewModel(messageCount: 1000)
        vm.lastPaginationAnchor = Date()
        vm.trimToRecentWindowIfAtBottom(isAtBottom: true)
        XCTAssertNil(vm.lastPaginationAnchor)
    }

    /// An unread divider pointing at a dropped message would draw above
    /// nothing.
    func testUnreadDividerIsClearedOnlyIfItsMessageWentAway() {
        let dropped = makeViewModel(messageCount: 1000)
        dropped.firstUnreadMessageId = "m0"
        dropped.trimToRecentWindowIfAtBottom(isAtBottom: true)
        XCTAssertNil(dropped.firstUnreadMessageId)

        let kept = makeViewModel(messageCount: 1000)
        kept.firstUnreadMessageId = "m999"
        kept.trimToRecentWindowIfAtBottom(isAtBottom: true)
        XCTAssertEqual(kept.firstUnreadMessageId, "m999", "a surviving divider must stay")
    }

    /// Sections drive what is drawn, so they have to reflect the new window.
    func testSectionsAreRebuiltFromTheTrimmedWindow() {
        let vm = makeViewModel(messageCount: 1000)
        vm.trimToRecentWindowIfAtBottom(isAtBottom: true)
        let inSections = vm.messageSections.reduce(0) { $0 + $1.messages.count }
        XCTAssertEqual(inSections, ChatDetailViewModel.retainedWindowSize)
    }

    /// Trimming twice must be a no-op rather than eating into the window.
    func testTrimmingIsIdempotent() {
        let vm = makeViewModel(messageCount: 1000)
        vm.trimToRecentWindowIfAtBottom(isAtBottom: true)
        let after = vm.messages.map(\.id)
        XCTAssertFalse(vm.trimToRecentWindowIfAtBottom(isAtBottom: true))
        XCTAssertEqual(vm.messages.map(\.id), after)
    }

    /// The retained window has to be comfortably more than a screenful, or
    /// returning to the bottom would immediately need to page again.
    func testWindowIsLargerThanAScreenful() {
        XCTAssertGreaterThan(ChatDetailViewModel.retainedWindowSize, 50)
        XCTAssertGreaterThan(
            ChatDetailViewModel.trimThreshold,
            ChatDetailViewModel.retainedWindowSize,
            "trimming must remove something when it runs"
        )
    }
}
