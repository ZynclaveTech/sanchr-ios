import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Replies travel inside the sealed envelope.
///
/// They previously travelled nowhere at all: the proto has no reply field, and
/// the send path dropped the reference before the message was even built. The
/// banner appeared, the message went out, and nothing anywhere recorded what it
/// was answering.
final class ReplyPayloadTests: XCTestCase {

    private func encoded(_ payload: InnerPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testReplyIdSurvivesAJSONRoundTrip() throws {
        let payload = InnerPayload(
            conversationId: "c1",
            contentType: "text",
            content: Data("hi".utf8),
            isSync: false,
            replyToMessageId: "m-42"
        )
        let decoded = try JSONDecoder().decode(
            InnerPayload.self,
            from: try JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded.replyToMessageId, "m-42")
    }

    /// The key must stay `reply_to_message_id`. Android reads the same JSON, so
    /// renaming it silently breaks replies across platforms rather than failing
    /// a build.
    func testWireKeyIsSnakeCase() throws {
        let json = try encoded(
            InnerPayload(
                conversationId: "c1",
                contentType: "text",
                content: Data(),
                isSync: false,
                replyToMessageId: "m-1"
            )
        )
        XCTAssertEqual(json["reply_to_message_id"] as? String, "m-1")
    }

    /// A message that answers nothing must not put the key on the wire, so
    /// ordinary sends stay byte-identical to what older clients produce.
    func testAnOrdinaryMessageOmitsTheKeyEntirely() throws {
        let json = try encoded(
            InnerPayload(
                conversationId: "c1",
                contentType: "text",
                content: Data(),
                isSync: false
            )
        )
        XCTAssertNil(json["reply_to_message_id"])
    }

    /// A payload from a client predating the field must still decode. This is
    /// the compatibility guarantee the whole optional-field approach rests on.
    func testAPayloadWithoutTheFieldStillDecodes() throws {
        let legacy = """
        {"v":1,"conversation_id":"c1","content_type":"text",
         "content":"aGk=","is_sync":false}
        """
        let decoded = try JSONDecoder().decode(
            InnerPayload.self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(decoded.replyToMessageId)
        XCTAssertEqual(decoded.conversationId, "c1")
    }

    /// The reply must be readable before the conversation is cleared. The bug
    /// was ordering: `clearReply()` ran first, so the id was already nil by the
    /// time the outgoing message was constructed.
    func testTextMessageFactoryCarriesTheReply() {
        let message = Message.textMessage(
            conversationId: "c1",
            senderId: "me",
            text: "agreed",
            isOutgoing: true,
            replyToMessageId: "m-7"
        )
        XCTAssertEqual(message.replyToMessageId, "m-7")
    }

    func testTextMessageFactoryDefaultsToNoReply() {
        let message = Message.textMessage(
            conversationId: "c1",
            senderId: "me",
            text: "hello",
            isOutgoing: true
        )
        XCTAssertNil(message.replyToMessageId)
    }
}
