// Tests/UnitTests/Platform/Calls/CallSetupFailureTests.swift
import XCTest
import GRPC
import NIOCore
import NIOEmbedded
@testable import Sanchr
import SanchrShared

/// What a call leaves behind when its setup fails part-way.
///
/// `startCall` runs local media before it talks to the server. When a later
/// step threw, the microphone stayed live, the peer connection stayed
/// configured, and `callState` stayed `.idle`, so nothing could tear it down.
final class CallSetupFailureTests: XCTestCase {

    struct SetupFailure: Error {}

    private final class FailingCallSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol, @unchecked Sendable {
        let channel: GRPCChannel
        var defaultCallOptions: CallOptions = CallOptions()
        var interceptors: Sanchr_Calling_CallSignalingServiceClientInterceptorFactoryProtocol? = nil
        var failTurn = false
        var failInitiate = false
        private let fakeChannel: FakeChannel

        init() {
            let fc = FakeChannel()
            fakeChannel = fc
            channel = fc
        }

        func callStream<RequestStream>(
            _ requests: RequestStream, callOptions: CallOptions? = nil
        ) -> GRPCAsyncResponseStream<Sanchr_Calling_CallSignal>
        where RequestStream: AsyncSequence & Sendable, RequestStream.Element == Sanchr_Calling_CallSignal {
            let fakeBidi: FakeStreamingResponse<Sanchr_Calling_CallSignal, Sanchr_Calling_CallSignal> =
                fakeChannel.makeFakeStreamingResponse(
                    path: Sanchr_Calling_CallSignalingServiceClientMetadata.Methods.callStream.path,
                    requestHandler: { _ in }
                )
            try? fakeBidi.sendEnd()
            return performAsyncBidirectionalStreamingCall(
                path: Sanchr_Calling_CallSignalingServiceClientMetadata.Methods.callStream.path,
                requests: requests, callOptions: callOptions ?? defaultCallOptions, interceptors: []
            )
        }

        func initiateCall(_ request: Sanchr_Calling_CallOffer, callOptions: CallOptions? = nil) async throws -> Sanchr_Calling_CallResponse {
            if failInitiate { throw SetupFailure() }
            var response = Sanchr_Calling_CallResponse()
            response.callID = "test-call-id"
            response.status = "ringing"
            return response
        }

        func getTurnCredentials(_ request: Sanchr_Calling_GetTurnCredentialsRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Calling_TurnCredentials {
            if failTurn { throw SetupFailure() }
            return Sanchr_Calling_TurnCredentials()
        }

        func endCall(_ request: Sanchr_Calling_EndCallRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Calling_EndCallResponse {
            Sanchr_Calling_EndCallResponse()
        }

        func getCallHistory(_ request: Sanchr_Calling_GetCallHistoryRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Calling_GetCallHistoryResponse {
            Sanchr_Calling_GetCallHistoryResponse()
        }

        func makeInitiateCallCall(_ request: Sanchr_Calling_CallOffer, callOptions: CallOptions?) -> GRPCAsyncUnaryCall<Sanchr_Calling_CallOffer, Sanchr_Calling_CallResponse> {
            fatalError("unary methods are shadowed")
        }
        func makeCallStreamCall(callOptions: CallOptions?) -> GRPCAsyncBidirectionalStreamingCall<Sanchr_Calling_CallSignal, Sanchr_Calling_CallSignal> {
            fatalError("unary methods are shadowed")
        }
        func makeEndCallCall(_ request: Sanchr_Calling_EndCallRequest, callOptions: CallOptions?) -> GRPCAsyncUnaryCall<Sanchr_Calling_EndCallRequest, Sanchr_Calling_EndCallResponse> {
            fatalError("unary methods are shadowed")
        }
        func makeGetCallHistoryCall(_ request: Sanchr_Calling_GetCallHistoryRequest, callOptions: CallOptions?) -> GRPCAsyncUnaryCall<Sanchr_Calling_GetCallHistoryRequest, Sanchr_Calling_GetCallHistoryResponse> {
            fatalError("unary methods are shadowed")
        }
        func makeGetTurnCredentialsCall(_ request: Sanchr_Calling_GetTurnCredentialsRequest, callOptions: CallOptions?) -> GRPCAsyncUnaryCall<Sanchr_Calling_GetTurnCredentialsRequest, Sanchr_Calling_TurnCredentials> {
            fatalError("unary methods are shadowed")
        }
    }

    private func assertNothingLeft(_ manager: CallManager, _ client: WebRTCClient, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(manager.callState, .idle, file: file, line: line)
        XCTAssertFalse(client.hasLocalMedia, "local media must be stopped", file: file, line: line)
        XCTAssertFalse(client.hasPeerConnection, "peer connection must be closed", file: file, line: line)
        XCTAssertEqual(manager.callType, "voice", file: file, line: line)
        XCTAssertFalse(manager.isVideoEnabled, file: file, line: line)
    }

    /// The server rejects the offer after local media and the peer
    /// connection are already up.
    func testAFailedInitiateLeavesNothingRunning() async throws {
        let service = FailingCallSignalingService()
        service.failInitiate = true
        let client = WebRTCClient()
        let manager = CallManager(webRTCClient: client, callService: service, signalManager: MockSignalManager())

        do {
            try await manager.startCall(recipientId: "bob", recipientName: "Bob", isVideo: false)
            XCTFail("startCall must rethrow")
        } catch is SetupFailure {
            assertNothingLeft(manager, client)
        } catch {
            throw XCTSkip("WebRTC unavailable in this environment: \(error.localizedDescription)")
        }
    }

    func testAFailedTurnFetchLeavesTheManagerIdle() async throws {
        let service = FailingCallSignalingService()
        service.failTurn = true
        let client = WebRTCClient()
        let manager = CallManager(webRTCClient: client, callService: service, signalManager: MockSignalManager())

        await XCTAssertThrowsErrorAsync(try await manager.startCall(recipientId: "bob", recipientName: "Bob", isVideo: false))
        assertNothingLeft(manager, client)
    }

    // MARK: - Wiring

    private func source() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Platform/Calls/CallManager.swift"),
            encoding: .utf8
        )
    }

    private func body(of function: String, in text: String, length: Int = 1200) throws -> String {
        let start = try XCTUnwrap(text.range(of: function), "\(function) not found")
        return String(text[start.upperBound...].prefix(length))
    }

    /// The CallKit path that calls answerCall swallows the error, so the
    /// manager itself must tear down and keep a reason to show.
    func testAFailedAnswerTearsDownAndKeepsAReason() throws {
        let text = try source()
        let answer = try body(of: "func answerCall() async throws {", in: text, length: 3000)
        XCTAssertTrue(answer.contains("abandonAnswer(callId: callId, after: error)"))
        let abandon = try body(of: "func abandonAnswer(callId: String, after error: Error) {", in: text, length: 400)
        XCTAssertTrue(abandon.contains("lastCallError ="))
        XCTAssertTrue(abandon.contains("endCallInternal(callId: callId, reason: .failed, notifyServer: true)"))
    }

    func testACallKitAnswerRefusalKeepsAReason() throws {
        let request = try body(of: "func requestAnswerCall() async throws {", in: try source())
        XCTAssertTrue(request.contains("lastCallError ="))
    }

    /// WebRTC delivers local candidates on its own thread; every sibling
    /// callback hops to the main actor and this one did not.
    func testLocalCandidatesAreHandledOnTheMainActor() throws {
        let handler = try body(of: "didReceiveLocalCandidate candidate: RTCIceCandidate) {", in: try source(), length: 800)
        XCTAssertTrue(handler.contains("Task { @MainActor"))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
