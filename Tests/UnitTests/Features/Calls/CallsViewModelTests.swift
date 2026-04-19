import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class CallsViewModelTests: XCTestCase {

    func testFilterByCallTypeAndVideo() {
        let viewModel = CallsViewModel()
        viewModel.callHistory = [
            entry(id: "incoming", type: .incoming, isVideo: false),
            entry(id: "outgoing-video", type: .outgoing, isVideo: true),
            entry(id: "missed", type: .missed, isVideo: false),
        ]

        viewModel.selectedFilter = .missed
        XCTAssertEqual(viewModel.filteredCallHistory.map(\.id), ["missed"])

        viewModel.selectedFilter = .incoming
        XCTAssertEqual(viewModel.filteredCallHistory.map(\.id), ["incoming"])

        viewModel.selectedFilter = .outgoing
        XCTAssertEqual(viewModel.filteredCallHistory.map(\.id), ["outgoing-video"])

        viewModel.selectedFilter = .video
        XCTAssertEqual(viewModel.filteredCallHistory.map(\.id), ["outgoing-video"])
    }

    func testSearchMatchesDisplayNameAndFallbackIdentifiers() {
        let viewModel = CallsViewModel()
        viewModel.callHistory = [
            entry(id: "alice", contactId: "alice-id", contactName: "Alice Rao"),
            entry(id: "phone", contactId: "+15551234567", contactName: "+15551234567"),
        ]

        viewModel.searchText = "rao"
        XCTAssertEqual(viewModel.filteredCallHistory.map(\.id), ["alice"])

        viewModel.searchText = "555123"
        XCTAssertEqual(viewModel.filteredCallHistory.map(\.id), ["phone"])
    }

    func testGroupsHistoryByTodayYesterdayAndEarlier() {
        let viewModel = CallsViewModel()
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let earlier = calendar.date(byAdding: .day, value: -3, to: now)!

        viewModel.callHistory = [
            entry(id: "today", timestamp: now),
            entry(id: "yesterday", timestamp: yesterday),
            entry(id: "earlier", timestamp: earlier),
        ]

        XCTAssertEqual(viewModel.groupedCallHistory.map(\.id), [.today, .yesterday, .earlier])
        XCTAssertEqual(viewModel.groupedCallHistory.map { $0.entries.map(\.id) }, [["today"], ["yesterday"], ["earlier"]])
    }

    func testEnrichHistoryUsesContactsThenConversationParticipants() {
        let viewModel = CallsViewModel()
        let contactAvatar = URL(string: "https://example.com/alice.jpg")!
        let conversationAvatar = URL(string: "https://example.com/bob.jpg")!
        let entries = [
            entry(id: "alice-call", contactId: "alice", contactName: "alice"),
            entry(id: "bob-call", contactId: "bob", contactName: "bob"),
            entry(id: "uuid-call", contactId: "uuid-user", contactName: "00000000-0000-0000-0000-000000000000"),
        ]
        let contacts = [
            user(id: "alice", displayName: "Alice Contact", avatarURL: contactAvatar),
            user(id: "uuid-user", phoneNumber: "+919999999999", displayName: "00000000-0000-0000-0000-000000000000"),
        ]
        let conversations = [
            conversation(participants: [
                user(id: "local", displayName: "Me", isLocalUser: true),
                user(id: "bob", displayName: "Bob Conversation", avatarURL: conversationAvatar),
            ]),
        ]

        let enriched = viewModel.enrichCallHistory(entries, contacts: contacts, conversations: conversations)

        XCTAssertEqual(enriched.first(where: { $0.id == "alice-call" })?.displayName, "Alice Contact")
        XCTAssertEqual(enriched.first(where: { $0.id == "alice-call" })?.avatarURL, contactAvatar)
        XCTAssertEqual(enriched.first(where: { $0.id == "bob-call" })?.displayName, "Bob Conversation")
        XCTAssertEqual(enriched.first(where: { $0.id == "bob-call" })?.avatarURL, conversationAvatar)
        XCTAssertEqual(enriched.first(where: { $0.id == "uuid-call" })?.displayName, "+919999999999")
    }

    func testNewCallContactSearchFiltersByNamePhoneAndBio() {
        let viewModel = CallsViewModel()
        viewModel.newCallContacts = [
            user(id: "alice", phoneNumber: "+111", displayName: "Alice Rao", bio: "Design"),
            user(id: "bob", phoneNumber: "+15551234567", displayName: "Bob Chen", bio: "Product"),
        ]

        viewModel.contactSearchText = "design"
        XCTAssertEqual(viewModel.filteredNewCallContacts.map(\.id), ["alice"])

        viewModel.contactSearchText = "555123"
        XCTAssertEqual(viewModel.filteredNewCallContacts.map(\.id), ["bob"])
    }

    private func entry(
        id: String,
        contactId: String = "peer",
        contactName: String = "Peer",
        timestamp: Date = Date(),
        duration: TimeInterval = 70,
        type: CallHistoryEntry.CallType = .incoming,
        isVideo: Bool = false,
        avatarURL: URL? = nil
    ) -> CallHistoryEntry {
        CallHistoryEntry(
            id: id,
            contactId: contactId,
            contactName: contactName,
            timestamp: timestamp,
            duration: duration,
            type: type,
            isVideo: isVideo,
            avatarURL: avatarURL
        )
    }

    private func user(
        id: String,
        phoneNumber: String = "",
        displayName: String,
        avatarURL: URL? = nil,
        bio: String? = nil,
        isVerified: Bool = false,
        status: User.Status = .offline,
        isLocalUser: Bool = false
    ) -> User {
        User(
            id: id,
            phoneNumber: phoneNumber,
            displayName: displayName,
            avatarURL: avatarURL,
            bio: bio,
            isVerified: isVerified,
            status: status,
            isLocalUser: isLocalUser
        )
    }

    private func conversation(participants: [User]) -> Conversation {
        Conversation(
            id: UUID().uuidString,
            participants: participants,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
