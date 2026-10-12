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

    // MARK: - Keepalive
    //
    // The ingress closes a stream the client has sent nothing on for sixty
    // seconds. Nothing fed it once the presence heartbeat was removed, so an
    // idle app lost its stream every minute.

    func test_anOpenStreamIsSentKeepalivesThatCarryNoEvent() async {
        let controller = MessageStreamController(keepAliveInterval: 0.05)

        let stream = await controller.begin()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        // The server matches on the event and ignores a message without
        // one; anything set here would be acted on.
        XCTAssertNotNil(first)
        XCTAssertNil(first?.event)
        XCTAssertNotNil(second, "one keepalive is not a heartbeat")
        XCTAssertNil(second?.event)
        await controller.finish()
    }

    func test_keepalivesStopWhenTheStreamIsFinished() async {
        let controller = MessageStreamController(keepAliveInterval: 0.05)
        let stream = await controller.begin()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        await controller.finish()

        // A finished stream ends; it is not fed for ever.
        var remaining = 0
        while await iterator.next() != nil { remaining += 1 }
        XCTAssertLessThanOrEqual(remaining, 1, "only one already in flight may still arrive")
    }

    func test_aKeepaliveIsNotHeldForTheNextStream() async {
        let controller = MessageStreamController(keepAliveInterval: 0.05)
        let first = await controller.begin()
        var firstIterator = first.makeAsyncIterator()
        _ = await firstIterator.next()
        await controller.finish()
        try? await Task.sleep(nanoseconds: 200_000_000)

        var typing = Sanchr_Messaging_TypingIndicator()
        typing.conversationID = "conversation-1"
        var real = Sanchr_Messaging_ClientEvent()
        real.typing = typing
        await controller.send(real)

        let second = await controller.begin()
        var secondIterator = second.makeAsyncIterator()
        let received = await secondIterator.next()

        XCTAssertEqual(
            received?.typing.conversationID,
            "conversation-1",
            "stale keepalives were queued ahead of what the app had to say"
        )
        await controller.finish()
    }
}
