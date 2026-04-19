import XCTest
import SanchrShared
@testable import Sanchr

final class MessageRepositoryUndeliverableSealedTests: XCTestCase {

    func testUndeliverableSealedDecodeFailureIsAckedToStopReplay() {
        let error = AppError.decryptionFailed(
            reason: "Sealed envelope could not be decrypted by any of 2 known session(s)"
        )

        XCTAssertTrue(MessageRepositoryImpl.shouldAckUndeliverableSealedMessage(error))
    }

    func testNoActiveSessionsFailureIsLeftForRetry() {
        let error = AppError.decryptionFailed(
            reason: "No active sessions to trial-decrypt sealed envelope"
        )

        XCTAssertFalse(MessageRepositoryImpl.shouldAckUndeliverableSealedMessage(error))
    }

    func testCorruptInnerPayloadFailureIsAckedToStopReplay() {
        let error = NSError(domain: "InnerPayload", code: 1)

        XCTAssertTrue(MessageRepositoryImpl.shouldAckUndeliverableSealedMessage(error))
    }

    func testReplayGateRejectsDuplicateWhileInFlight() async {
        let gate = MessageEnvelopeReplayGate(limit: 4)

        let firstBegin = await gate.begin("message-1")
        let secondBegin = await gate.begin("message-1")

        XCTAssertTrue(firstBegin)
        XCTAssertFalse(secondBegin)
    }

    func testReplayGateRejectsRememberedEnvelope() async {
        let gate = MessageEnvelopeReplayGate(limit: 4)

        let firstBegin = await gate.begin("message-1")
        await gate.finish("message-1", remember: true)
        let secondBegin = await gate.begin("message-1")

        XCTAssertTrue(firstBegin)
        XCTAssertFalse(secondBegin)
    }

    func testReplayGateAllowsRetryWhenNotRemembered() async {
        let gate = MessageEnvelopeReplayGate(limit: 4)

        let firstBegin = await gate.begin("message-1")
        await gate.finish("message-1", remember: false)
        let secondBegin = await gate.begin("message-1")

        XCTAssertTrue(firstBegin)
        XCTAssertTrue(secondBegin)
    }

    func testReplayGateEvictsOldRememberedEnvelope() async {
        let gate = MessageEnvelopeReplayGate(limit: 1)

        let firstBegin = await gate.begin("message-1")
        await gate.finish("message-1", remember: true)
        let secondBegin = await gate.begin("message-2")
        await gate.finish("message-2", remember: true)
        let evictedBegin = await gate.begin("message-1")

        XCTAssertTrue(firstBegin)
        XCTAssertTrue(secondBegin)
        XCTAssertTrue(evictedBegin)
    }
}
