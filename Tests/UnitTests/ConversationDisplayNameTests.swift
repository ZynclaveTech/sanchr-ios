import Foundation
import SanchrShared
import XCTest

/// A group's title is the other members. The local user is a participant
/// too, and until this was fixed every group in the list carried the
/// user's own name.
final class ConversationDisplayNameTests: XCTestCase {

    private func user(_ name: String, isLocal: Bool = false) -> User {
        User(id: name.lowercased(), phoneNumber: "", displayName: name, isVerified: false, status: .offline, isLocalUser: isLocal)
    }

    private func conversation(_ participants: [User], type: Conversation.ConversationType) -> Conversation {
        Conversation(id: "c", participants: participants, unreadCount: 0, isPinned: false, isMuted: false,
                     isArchived: false, type: type, createdAt: Date(), updatedAt: Date())
    }

    func testAGroupTitleLeavesTheLocalUserOut() {
        let c = conversation([user("Me", isLocal: true), user("Asha"), user("Ravi")], type: .group)
        XCTAssertEqual(c.displayName, "Asha, Ravi")
    }

    func testAGroupWithNoOneElseStillHasATitle() {
        let c = conversation([user("Me", isLocal: true)], type: .group)
        XCTAssertEqual(c.displayName, "Group")
    }

    func testAOneToOneTitleIsTheOtherPerson() {
        let c = conversation([user("Me", isLocal: true), user("Asha")], type: .oneToOne)
        XCTAssertEqual(c.displayName, "Asha")
    }
}
