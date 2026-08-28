import Foundation
import UIKit
import XCTest
import SanchrShared

@testable import Sanchr

/// The home list rebuilds its visible rows from the `searchText` `didSet`, so
/// this runs on every keystroke. It was restructured to filter before sorting;
/// these pin the behaviour that had to survive that.
@MainActor
final class ChatsListFilteringTests: XCTestCase {

    private func conversation(
        _ name: String,
        unread: Int = 0,
        pinned: Bool = false,
        archived: Bool = false,
        group: Bool = false,
        minutesAgo: Int = 0
    ) -> Conversation {
        let peer = User(
            id: "peer-\(name)",
            phoneNumber: "",
            displayName: name,
            avatarURL: nil,
            bio: nil,
            isVerified: false,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline
        )
        let me = User(
            id: "me", phoneNumber: "", displayName: "You", avatarURL: nil, bio: nil,
            isVerified: true, lastSeen: nil, identityKeyFingerprint: nil, status: .online,
            isLocalUser: true
        )
        return Conversation(
            id: "conv-\(name)",
            participants: [me, peer],
            lastMessage: nil,
            unreadCount: unread,
            isPinned: pinned,
            isMuted: false,
            isArchived: archived,
            type: group ? .group : .oneToOne,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
        )
    }

    private func names(_ vm: ChatsListViewModel) -> [String] {
        (vm.pinnedConversations + vm.recentConversations).map(\.displayName)
    }

    // MARK: - Ordering

    func testPinnedSortFirstThenMostRecent() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("Old", minutesAgo: 60),
            conversation("Pinned", pinned: true, minutesAgo: 90),
            conversation("Recent", minutesAgo: 1),
        ]

        XCTAssertEqual(vm.pinnedConversations.map(\.displayName), ["Pinned"])
        XCTAssertEqual(
            vm.recentConversations.map(\.displayName), ["Recent", "Old"],
            "unpinned rows are newest first"
        )
    }

    func testArchivedAreExcluded() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("Visible"), conversation("Gone", archived: true)]
        XCTAssertEqual(names(vm), ["Visible"])
    }

    // MARK: - Filters

    func testUnreadFilter() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("Read"), conversation("Unread", unread: 3)]
        vm.selectedFilter = .unread
        XCTAssertEqual(names(vm), ["Unread"])
    }

    func testGroupsFilter() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("Direct"), conversation("Team", group: true)]
        vm.selectedFilter = .groups

        // A group has no stored name yet, so `displayName` joins every
        // participant — the local user included, hence the "You, " prefix.
        // Asserted as-is rather than worked around: it is existing behaviour
        // this change must not alter, and it is flagged with a TODO in
        // `Conversation.displayName`.
        XCTAssertEqual(names(vm), ["You, Team"])
    }

    /// Sorting now happens after filtering, so ordering has to survive a filter.
    func testOrderingHoldsWithAFilterApplied() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("OldUnread", unread: 1, minutesAgo: 90),
            conversation("PinnedUnread", unread: 1, pinned: true, minutesAgo: 120),
            conversation("NewUnread", unread: 1, minutesAgo: 2),
            conversation("Read", minutesAgo: 1),
        ]
        vm.selectedFilter = .unread
        XCTAssertEqual(names(vm), ["PinnedUnread", "NewUnread", "OldUnread"])
    }

    // MARK: - Search

    func testSearchMatchesOnName() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("Alice"), conversation("Bob")]
        vm.searchText = "ali"
        XCTAssertEqual(names(vm), ["Alice"])
    }

    func testSearchIsCaseInsensitive() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("Alice")]
        vm.searchText = "ALICE"
        XCTAssertEqual(names(vm), ["Alice"])
    }

    /// Gained by moving to `localizedStandardContains`: accented names are now
    /// findable without typing the accent.
    func testSearchIgnoresDiacritics() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("José")]
        vm.searchText = "jose"
        XCTAssertEqual(names(vm), ["José"], "diacritic-insensitive search")
    }

    /// A query of only spaces is not a search — it must not empty the list.
    func testWhitespaceOnlySearchShowsEverything() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("Alice"), conversation("Bob")]
        vm.searchText = "   "
        XCTAssertEqual(names(vm).count, 2)
    }

    func testSearchCombinesWithFilter() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("Alice", unread: 2),
            conversation("Alice Read"),
            conversation("Bob", unread: 1),
        ]
        vm.selectedFilter = .unread
        vm.searchText = "alice"
        XCTAssertEqual(names(vm), ["Alice"])
    }

    // MARK: - Unread total

    /// The total moved off the filter/search path; it must still track the
    /// conversation set, and must ignore both archived rows and the filter.
    func testTotalUnreadIgnoresArchived() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("A", unread: 2),
            conversation("B", unread: 3),
            conversation("Archived", unread: 99, archived: true),
        ]
        XCTAssertEqual(vm.totalUnreadCount, 5)
    }

    func testTotalUnreadIsUnaffectedByFilterAndSearch() {
        let vm = ChatsListViewModel()
        vm.conversations = [conversation("A", unread: 2), conversation("B", unread: 3)]
        vm.selectedFilter = .groups
        vm.searchText = "zzz"

        XCTAssertTrue(names(vm).isEmpty, "precondition: nothing is visible")
        XCTAssertEqual(vm.totalUnreadCount, 5, "the badge counts the account, not the view")
    }

    // MARK: - Sort order

    private func clearPersistedSortOrder() {
        UserDefaults.standard.removeObject(forKey: ChatsListViewModel.sortOrderStorageKey)
    }

    /// Pinning is the user saying "keep this at the top"; no sort may override it.
    func testPinnedStayFirstUnderEverySortOrder() {
        for order in ChatsListViewModel.SortOrder.allCases {
            let vm = ChatsListViewModel()
            vm.conversations = [
                conversation("Zoe", unread: 9, minutesAgo: 0),
                conversation("Anna", pinned: true, minutesAgo: 500),
            ]
            vm.sortOrder = order
            XCTAssertEqual(
                vm.pinnedConversations.map(\.displayName), ["Anna"],
                "\(order.label) must not displace a pinned row"
            )
        }
        clearPersistedSortOrder()
    }

    func testRecentOrder() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("Old", minutesAgo: 90),
            conversation("New", minutesAgo: 1),
        ]
        vm.sortOrder = .recent
        XCTAssertEqual(names(vm), ["New", "Old"])
        clearPersistedSortOrder()
    }

    /// Unread leads, but within the unread group it is recency that decides —
    /// ordering by raw count would bury a message that just arrived under a
    /// thread carrying a large backlog.
    func testUnreadFirstOrdersByRecencyNotCount() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("Backlog", unread: 50, minutesAgo: 120),
            conversation("JustArrived", unread: 1, minutesAgo: 1),
            conversation("Read", minutesAgo: 0),
        ]
        vm.sortOrder = .unreadFirst
        XCTAssertEqual(names(vm), ["JustArrived", "Backlog", "Read"])
        clearPersistedSortOrder()
    }

    func testNameOrderIsCaseAndDiacriticInsensitive() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("zoe", minutesAgo: 0),
            conversation("Ábel", minutesAgo: 0),
            conversation("Bob", minutesAgo: 0),
        ]
        vm.sortOrder = .name
        XCTAssertEqual(names(vm), ["Ábel", "Bob", "zoe"])
        clearPersistedSortOrder()
    }

    /// Names are not unique. Equal names must not shuffle between rebuilds.
    func testEqualNamesFallBackToRecency() {
        let vm = ChatsListViewModel()
        var older = conversation("Sam", minutesAgo: 60)
        var newer = conversation("Sam", minutesAgo: 1)
        older = Conversation(
            id: "older", participants: older.participants, lastMessage: nil, unreadCount: 0,
            isPinned: false, isMuted: false, isArchived: false, type: .oneToOne,
            createdAt: older.createdAt, updatedAt: older.updatedAt
        )
        newer = Conversation(
            id: "newer", participants: newer.participants, lastMessage: nil, unreadCount: 0,
            isPinned: false, isMuted: false, isArchived: false, type: .oneToOne,
            createdAt: newer.createdAt, updatedAt: newer.updatedAt
        )
        vm.conversations = [older, newer]
        vm.sortOrder = .name
        XCTAssertEqual(
            (vm.pinnedConversations + vm.recentConversations).map(\.id), ["newer", "older"]
        )
        clearPersistedSortOrder()
    }

    func testSortOrderPersistsAndRestores() {
        clearPersistedSortOrder()
        let first = ChatsListViewModel()
        first.sortOrder = .name

        let second = ChatsListViewModel()
        XCTAssertEqual(second.sortOrder, .recent, "a fresh view model starts at the default")
        second.restorePersistedSortOrder()
        XCTAssertEqual(second.sortOrder, .name, "the persisted choice is restored")
        clearPersistedSortOrder()
    }

    func testSortAppliesUnderSearchAndFilter() {
        let vm = ChatsListViewModel()
        vm.conversations = [
            conversation("Alice Zulu", unread: 1, minutesAgo: 90),
            conversation("Alice Alpha", unread: 1, minutesAgo: 5),
            conversation("Bob", unread: 1, minutesAgo: 0),
        ]
        vm.selectedFilter = .unread
        vm.searchText = "alice"
        vm.sortOrder = .name
        XCTAssertEqual(names(vm), ["Alice Alpha", "Alice Zulu"])
        clearPersistedSortOrder()
    }

    /// A bad SF Symbol name fails silently — the menu just renders a blank
    /// space where the icon should be, which is how `circle.badge.fill`
    /// (correct name: `circlebadge.fill`) shipped. `UIImage(systemName:)`
    /// returns nil for a name the system does not know, so this catches it.
    func testEverySortOrderHasAResolvableIcon() {
        for order in ChatsListViewModel.SortOrder.allCases {
            XCTAssertNotNil(
                UIImage(systemName: order.systemImage),
                "\(order.label) uses '\(order.systemImage)', which is not a valid SF Symbol"
            )
        }
    }

    func testEverySortOrderHasALabel() {
        for order in ChatsListViewModel.SortOrder.allCases {
            XCTAssertFalse(order.label.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
