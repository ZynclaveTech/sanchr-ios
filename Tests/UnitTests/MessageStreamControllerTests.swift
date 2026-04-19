import XCTest
import SanchrShared
@testable import Sanchr

final class MessageStreamControllerTests: XCTestCase {

    func test_sendBeforeBegin_buffersEventUntilStreamStarts() async {
        let controller = MessageStreamController()

        var typing = Sanchr_Messaging_TypingIndicator()
        typing.conversationID = "conversation-1"
        typing.userID = "peer-1"
        typing.isTyping = true

        var clientEvent = Sanchr_Messaging_ClientEvent()
        clientEvent.typing = typing

        await controller.send(clientEvent)

        let stream = await controller.begin()
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()

        XCTAssertEqual(received?.typing.conversationID, "conversation-1")
        XCTAssertEqual(received?.typing.userID, "peer-1")
        XCTAssertEqual(received?.typing.isTyping, true)
    }
}
