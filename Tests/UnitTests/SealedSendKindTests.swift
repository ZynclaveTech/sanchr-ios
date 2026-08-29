import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Which sealed sends wake an offline phone with a notification.
///
/// Read receipts, presence and profile-key delivery travel by the same RPC as
/// a message someone typed. The envelope is sealed, so the server cannot tell
/// them apart and alerted for all of them alike — which is why starting a call
/// produced a "New message" notification sitting next to the call.
final class SealedSendKindTests: XCTestCase {

    private func deviceMessages(_ count: Int) -> [Sanchr_Messaging_DeviceMessage] {
        (1...count).map { index in
            var dm = Sanchr_Messaging_DeviceMessage()
            dm.recipientID = "user-\(index)"
            dm.deviceID = Int32(index)
            dm.ciphertext = Data("envelope-\(index)".utf8)
            return dm
        }
    }

    private func repository() -> MessageRepositoryImpl {
        makeRepo(spyService: SpyMessagingService())
    }

    func testControlSendsAreMarkedSilent() {
        let built = repository().buildSealedDeviceMessages(from: deviceMessages(3), kind: .control)
        XCTAssertEqual(built.count, 3)
        XCTAssertTrue(built.allSatisfy(\.silent), "receipts, presence and keys must not alert")
    }

    /// The half that matters most. If a real message is ever marked silent, the
    /// recipient stops being notified — and only their phone shows it.
    func testMessageSendsAreNotSilent() {
        let built = repository().buildSealedDeviceMessages(from: deviceMessages(2), kind: .message)
        XCTAssertTrue(built.allSatisfy { !$0.silent }, "a message a person wrote must alert")
    }

    func testKindMapsToTheWireFlag() {
        XCTAssertTrue(MessageRepositoryImpl.SealedSendKind.control.isSilent)
        XCTAssertFalse(MessageRepositoryImpl.SealedSendKind.message.isSilent)
    }

    /// The builder replaced four hand-written copies of this mapping. Every
    /// field they set has to survive the consolidation, or a send goes to the
    /// wrong device with the wrong bytes.
    func testEveryFieldIsCarriedThrough() {
        let source = deviceMessages(2)
        let built = repository().buildSealedDeviceMessages(from: source, kind: .message)

        for (original, wire) in zip(source, built) {
            XCTAssertEqual(wire.recipientID, original.recipientID)
            XCTAssertEqual(wire.deviceID, original.deviceID)
            XCTAssertEqual(wire.sealedEnvelope, original.ciphertext)
        }
    }

    /// `conversation_id` is cleartext routing metadata the server reads to
    /// honour per-device mutes. Nothing passes it today, and it must stay
    /// empty until that is a deliberate decision — populating it would tell
    /// the server which conversation every sealed message belongs to.
    func testConversationIdIsOmittedUnlessAsked() {
        let built = repository().buildSealedDeviceMessages(from: deviceMessages(1), kind: .message)
        XCTAssertTrue(built[0].conversationID.isEmpty)

        let tagged = repository().buildSealedDeviceMessages(
            from: deviceMessages(1), kind: .message, conversationId: "conv-1"
        )
        XCTAssertEqual(tagged[0].conversationID, "conv-1")
    }

    /// An empty input must produce an empty request rather than a send with no
    /// recipients.
    func testEmptyInputProducesNothing() {
        XCTAssertTrue(repository().buildSealedDeviceMessages(from: [], kind: .control).isEmpty)
    }
}
