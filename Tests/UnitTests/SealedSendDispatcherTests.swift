import XCTest
@testable import SanchrShared

/// A device that is set up again has lost every session. The server is the
/// one party that can tell, and says so in answer to a send; these cover what
/// the sender then does about it.
final class SealedSendDispatcherTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [Sanchr_Messaging_SendSealedMessageRequest] = []
        private var _resets: [String] = []
        private var _encryptions = 0
        private var _tokens = 0
        private var answers: [Sanchr_Messaging_SendSealedMessageResponse]

        init(answers: [Sanchr_Messaging_SendSealedMessageResponse]) { self.answers = answers }

        var requests: [Sanchr_Messaging_SendSealedMessageRequest] { lock.withLock { _requests } }
        var resets: [String] { lock.withLock { _resets } }
        var encryptions: Int { lock.withLock { _encryptions } }
        var tokens: Int { lock.withLock { _tokens } }

        func answer(_ request: Sanchr_Messaging_SendSealedMessageRequest) -> Sanchr_Messaging_SendSealedMessageResponse {
            lock.withLock {
                _requests.append(request)
                return answers.isEmpty ? Sanchr_Messaging_SendSealedMessageResponse() : answers.removeFirst()
            }
        }
        func reset(_ userId: String, _ deviceId: Int32) { lock.withLock { _resets.append("\(userId).\(deviceId)") } }
        func encrypted() -> Int { lock.withLock { _encryptions += 1; return _encryptions } }
        func token() -> Data { lock.withLock { _tokens += 1; return Data([UInt8(_tokens)]) } }
    }

    private static let accepted: Sanchr_Messaging_SendSealedMessageResponse = {
        var response = Sanchr_Messaging_SendSealedMessageResponse()
        response.serverTimestamp = 99
        return response
    }()

    private static func refused(_ devices: (String, Int32, Bool)...) -> Sanchr_Messaging_SendSealedMessageResponse {
        var response = Sanchr_Messaging_SendSealedMessageResponse()
        response.staleDevices = devices.map { userId, deviceId, registered in
            var stale = Sanchr_Messaging_StaleDevice()
            stale.recipientID = userId
            stale.deviceID = deviceId
            stale.registered = registered
            return stale
        }
        return response
    }

    private static func message(to userId: String = "bob", device: Int32 = 1) -> Sanchr_Messaging_SealedDeviceMessage {
        var message = Sanchr_Messaging_SealedDeviceMessage()
        message.recipientID = userId
        message.deviceID = device
        message.sealedEnvelope = Data([1])
        return message
    }

    /// The session before the reset is with registration 4242; the one made
    /// after it is with 9001.
    private func dispatcher(_ recorder: Recorder) -> SealedSendDispatcher {
        SealedSendDispatcher(
            send: { recorder.answer($0) },
            acquireToken: { recorder.token() },
            registrationId: { _, _ in recorder.resets.isEmpty ? 4242 : 9001 },
            resetSession: { recorder.reset($0, $1) }
        )
    }

    func testASendSaysWhichRegistrationItWasEncryptedFor() async throws {
        let recorder = Recorder(answers: [Self.accepted])

        let response = try await dispatcher(recorder).dispatch {
            _ = recorder.encrypted()
            return [Self.message()]
        }

        XCTAssertEqual(response?.serverTimestamp, 99)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].deviceMessages.map(\.recipientRegistrationID), [4242])
        XCTAssertEqual(recorder.requests[0].deliveryToken, Data([1]))
        XCTAssertTrue(recorder.resets.isEmpty)
        XCTAssertEqual(recorder.encryptions, 1)
    }

    func testToldASessionIsOutOfDateItStartsANewOneAndSendsAgain() async throws {
        let recorder = Recorder(answers: [Self.refused(("bob", 1, true)), Self.accepted])

        let response = try await dispatcher(recorder).dispatch {
            _ = recorder.encrypted()
            return [Self.message()]
        }

        XCTAssertEqual(response?.serverTimestamp, 99)
        XCTAssertEqual(recorder.resets, ["bob.1"])
        XCTAssertEqual(recorder.encryptions, 2, "encrypted again, after the reset")
        XCTAssertEqual(
            recorder.requests.map { $0.deviceMessages.map(\.recipientRegistrationID) }, [[4242], [9001]])
        // One token each: the server spends it before it looks.
        XCTAssertEqual(recorder.requests.map(\.deliveryToken), [Data([1]), Data([2])])
    }

    func testARefusalIsNeverReportedAsSent() async {
        let recorder = Recorder(answers: [Self.refused(("bob", 1, true)), Self.refused(("bob", 1, true))])

        do {
            _ = try await dispatcher(recorder).dispatch { [Self.message()] }
            XCTFail("a send the server refused twice must throw")
        } catch {
            XCTAssertEqual(error as? StaleSessionsError, StaleSessionsError(deviceCount: 1))
        }
        XCTAssertEqual(recorder.requests.count, 2, "once more, and no more")
    }

    /// The answer is about the request. A server that names anything else is
    /// not given the means to reset sessions it was never asked about.
    func testADeviceTheSendWasNotAddressedToIsNotResetOnTheServersWord() async throws {
        let recorder = Recorder(answers: [
            Self.refused(("carol", 1, true), ("bob", 2, true), ("bob", 1, true)), Self.accepted,
        ])

        _ = try await dispatcher(recorder).dispatch { [Self.message()] }

        XCTAssertEqual(recorder.resets, ["bob.1"])
    }

    func testADeviceThatIsGoneAltogetherLeavesNobodyToSendTo() async {
        let recorder = Recorder(answers: [Self.refused(("bob", 1, false))])

        do {
            _ = try await dispatcher(recorder).dispatch {
                recorder.encrypted() == 1 ? [Self.message()] : []
            }
            XCTFail("nothing was delivered, so it must not look sent")
        } catch {
            XCTAssertEqual(error as? StaleSessionsError, StaleSessionsError(deviceCount: 1))
        }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testNobodyToSendToSpendsNoTokenAndSendsNothing() async throws {
        let recorder = Recorder(answers: [])

        let response = try await dispatcher(recorder).dispatch { [] }

        XCTAssertNil(response)
        XCTAssertEqual(recorder.tokens, 0)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAFailureToEncryptAgainIsThrownNotSwallowed() async {
        struct EncryptFailed: Error {}
        let recorder = Recorder(answers: [Self.refused(("bob", 1, true))])

        do {
            _ = try await dispatcher(recorder).dispatch {
                if recorder.encrypted() == 2 { throw EncryptFailed() }
                return [Self.message()]
            }
            XCTFail("expected the second encryption's error")
        } catch {
            XCTAssertTrue(error is EncryptFailed)
        }
    }

    /// What a session-less conformer states: nothing, which is not checked.
    func testAnUnknownRegistrationIsLeftUnstated() async throws {
        let recorder = Recorder(answers: [Self.accepted])
        let dispatcher = SealedSendDispatcher(
            send: { recorder.answer($0) },
            acquireToken: { recorder.token() },
            registrationId: { _, _ in 0 },
            resetSession: { _, _ in }
        )

        _ = try await dispatcher.dispatch { [Self.message()] }

        XCTAssertEqual(recorder.requests[0].deviceMessages[0].recipientRegistrationID, 0)
    }
}
