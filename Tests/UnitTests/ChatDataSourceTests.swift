import XCTest
import SanchrShared

@testable import Sanchr

final class ChatDataSourceTests: XCTestCase {
    func testMapToDomainConversationUsesServerParticipantProfiles() {
        var conversation = Vync_Messaging_Conversation()
        conversation.id = "conversation-1"
        conversation.type = "direct"
        conversation.participantIds = ["local-user", "remote-user"]

        var localParticipant = Vync_Messaging_Participant()
        localParticipant.userID = "local-user"
        localParticipant.displayName = "Local User"

        var remoteParticipant = Vync_Messaging_Participant()
        remoteParticipant.userID = "remote-user"
        remoteParticipant.displayName = "Remote User"
        remoteParticipant.avatarURL = "https://cdn.example.com/avatar.png"

        conversation.participants = [localParticipant, remoteParticipant]

        let mapped = ChatDataSource.mapToDomainConversation(
            conversation,
            localUserId: "local-user"
        )

        XCTAssertEqual(mapped.displayName, "Remote User")
        XCTAssertEqual(
            mapped.avatarURL?.absoluteString,
            "https://cdn.example.com/avatar.png"
        )
        XCTAssertTrue(mapped.participants.contains { $0.id == "local-user" && $0.isLocalUser })
        XCTAssertTrue(mapped.participants.contains { $0.id == "remote-user" && !$0.isLocalUser })
    }
}
