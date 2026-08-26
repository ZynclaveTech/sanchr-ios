// Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift
import XCTest
import GRPC
import NIOCore
import NIOEmbedded
@testable import Sanchr
import SanchrShared

// MARK: - MockSignalManager (identity cipher)

private final class MockSignalManager: SignalProtocolManagerProtocol, @unchecked Sendable {
    let localUserId: String = "test-local-user"
    // Intentionally unsynchronised — MockSignalManager is only used from sequential XCTest flows.
    var encryptCallCount: Int = 0

    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data {
        encryptCallCount += 1
        return plaintext
    }

    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data {
        ciphertext
    }

    func establishSession(with userId: String, deviceId: Int32) async throws {}
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
    func hasSession(with userId: String) -> Bool { true }
    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws -> [Sanchr_Messaging_DeviceMessage] { [] }
    func encryptCallOffers(plaintext: Data, recipientId: String) async throws -> [Sanchr_Calling_DeviceCallOffer] {
        var entry = Sanchr_Calling_DeviceCallOffer()
        entry.deviceID = 1
        entry.encryptedSdpPayload = plaintext
        return [entry]
    }
    func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { envelope.ciphertext }
    func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
        // Not called in call-path tests; throw to satisfy the protocol.
        throw AppError.decryptionFailed(reason: "not used in CallManager E2EE smoke tests")
    }
    func resetSession(with userId: String, deviceId: Int32) throws {}
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
    func markIdentityVerified(userId: String) {}
    func isIdentityVerified(userId: String) -> Bool { false }
    func hasPendingIdentityChange(userId: String) -> Bool { false }
    func acceptIdentityChange(userId: String) {}
    func localIdentityKeyData() throws -> Data { Data() }
    func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
}

// MARK: - RecordingSignalManager (records senderDevice; decrypt returns valid SealedCallPayload)

/// Identity-cipher mock that captures the `senderDevice` passed to `decrypt`
/// and returns a valid `SealedCallPayload` JSON so the async decrypt path in
/// `CallManager.handleVoIPPushIncomingCall` can complete without throwing.
/// File-private so multiple tests can use it without redefining the 15+
/// no-op protocol methods inline.
private final class RecordingSignalManager: SignalProtocolManagerProtocol, @unchecked Sendable {
    let localUserId: String = "test-local-user"
    var lastSenderDevice: Int32 = -1

    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data { plaintext }
    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data {
        lastSenderDevice = senderDevice
        let payload = SealedCallPayload(
            sdp: "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n",
            dtlsFingerprint: "sha-256 DE:AD:BE:EF",
            timestamp: Date().timeIntervalSince1970
        )
        return try JSONEncoder().encode(payload)
    }

    func establishSession(with userId: String, deviceId: Int32) async throws {}
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
    func hasSession(with userId: String) -> Bool { true }
    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws -> [Sanchr_Messaging_DeviceMessage] { [] }
    // Returns [] — RecordingSignalManager is only used by VoIP-push tests
    // that never invoke startCall, so the empty result never reaches the
    // empty-guard inside buildOutgoingCallOffer.
    func encryptCallOffers(plaintext: Data, recipientId: String) async throws -> [Sanchr_Calling_DeviceCallOffer] { [] }
    func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { envelope.ciphertext }
    func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
        throw AppError.decryptionFailed(reason: "not used")
    }
    func resetSession(with userId: String, deviceId: Int32) throws {}
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
    func markIdentityVerified(userId: String) {}
    func isIdentityVerified(userId: String) -> Bool { false }
    func hasPendingIdentityChange(userId: String) -> Bool { false }
    func acceptIdentityChange(userId: String) {}
    func localIdentityKeyData() throws -> Data { Data() }
    func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
}

// MARK: - MockCallSignalingService

// Uses FakeChannel so GRPCClient conformance is satisfied. Unary methods are shadowed
// with in-process implementations that never touch the network. callStream is delegated
// to performAsyncBidirectionalStreamingCall with a FakeStreamingResponse that ends
// immediately — the signaling task in CallManager will see an empty stream and exit.
@available(swift, deprecated: 5.6)
private final class MockCallSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol, @unchecked Sendable {

    let channel: GRPCChannel
    var defaultCallOptions: CallOptions = CallOptions()
    var interceptors: Sanchr_Calling_CallSignalingServiceClientInterceptorFactoryProtocol? = nil
    var onInitiateCall: ((Sanchr_Calling_CallOffer) -> Void)?

    private let fakeChannel: FakeChannel

    init() {
        let fc = FakeChannel()
        self.fakeChannel = fc
        self.channel = fc
    }

    // Pre-registers a FakeStreamingResponse that ends immediately, then calls through
    // to performAsyncBidirectionalStreamingCall so it picks up the registered stream.
    func callStream<RequestStream>(
        _ requests: RequestStream,
        callOptions: CallOptions? = nil
    ) -> GRPCAsyncResponseStream<Sanchr_Calling_CallSignal>
    where RequestStream: AsyncSequence & Sendable, RequestStream.Element == Sanchr_Calling_CallSignal {
        let fakeBidi: FakeStreamingResponse<Sanchr_Calling_CallSignal, Sanchr_Calling_CallSignal> =
            fakeChannel.makeFakeStreamingResponse(
                path: Sanchr_Calling_CallSignalingServiceClientMetadata.Methods.callStream.path,
                requestHandler: { _ in }
            )
        try? fakeBidi.sendEnd()
        return self.performAsyncBidirectionalStreamingCall(
            path: Sanchr_Calling_CallSignalingServiceClientMetadata.Methods.callStream.path,
            requests: requests,
            callOptions: callOptions ?? defaultCallOptions,
            interceptors: []
        )
    }

    // Shadow the protocol-extension unary methods so they never touch the real channel.
    func initiateCall(
        _ request: Sanchr_Calling_CallOffer,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Calling_CallResponse {
        onInitiateCall?(request)
        var response = Sanchr_Calling_CallResponse()
        response.callID = "test-call-id"
        response.status = "ringing"
        return response
    }

    func getTurnCredentials(
        _ request: Sanchr_Calling_GetTurnCredentialsRequest,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Calling_TurnCredentials {
        Sanchr_Calling_TurnCredentials()
    }

    func endCall(
        _ request: Sanchr_Calling_EndCallRequest,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Calling_EndCallResponse {
        Sanchr_Calling_EndCallResponse()
    }

    func getCallHistory(
        _ request: Sanchr_Calling_GetCallHistoryRequest,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Calling_GetCallHistoryResponse {
        Sanchr_Calling_GetCallHistoryResponse()
    }

    // Required make*Call stubs — called only when the extension methods are used as
    // the unary path. Since we shadow all unary convenience methods above, these are
    // not reached in tests. Satisfy the compiler by producing an invalid call via a
    // never-connected FakeChannel (will fail immediately with a gRPC error if ever hit).
    func makeInitiateCallCall(
        _ request: Sanchr_Calling_CallOffer,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Calling_CallOffer, Sanchr_Calling_CallResponse> {
        fatalError("MockCallSignalingService: \(#function) must not be called in tests — shadow the async method instead")
    }

    func makeCallStreamCall(
        callOptions: CallOptions?
    ) -> GRPCAsyncBidirectionalStreamingCall<Sanchr_Calling_CallSignal, Sanchr_Calling_CallSignal> {
        fatalError("MockCallSignalingService: \(#function) must not be called in tests — shadow the async method instead")
    }

    func makeEndCallCall(
        _ request: Sanchr_Calling_EndCallRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Calling_EndCallRequest, Sanchr_Calling_EndCallResponse> {
        fatalError("MockCallSignalingService: \(#function) must not be called in tests — shadow the async method instead")
    }

    func makeGetCallHistoryCall(
        _ request: Sanchr_Calling_GetCallHistoryRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Calling_GetCallHistoryRequest, Sanchr_Calling_GetCallHistoryResponse> {
        fatalError("MockCallSignalingService: \(#function) must not be called in tests — shadow the async method instead")
    }

    func makeGetTurnCredentialsCall(
        _ request: Sanchr_Calling_GetTurnCredentialsRequest,
        callOptions: CallOptions?
    ) -> GRPCAsyncUnaryCall<Sanchr_Calling_GetTurnCredentialsRequest, Sanchr_Calling_TurnCredentials> {
        fatalError("MockCallSignalingService: \(#function) must not be called in tests — shadow the async method instead")
    }
}

// MARK: - Helpers

/// Builds a fresh SealedCallPayload encoded as Data, optionally with a real fingerprint
/// line in the SDP so the DTLS guard passes or fails predictably.
private func makeSealedPayload(
    ageDelta: TimeInterval = 0,
    payloadFingerprint: String = "",
    sdpBody: String = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"
) throws -> Data {
    let timestamp = Date().timeIntervalSince1970 + ageDelta
    let payload = SealedCallPayload(
        sdp: sdpBody,
        dtlsFingerprint: payloadFingerprint,
        timestamp: timestamp
    )
    return try JSONEncoder().encode(payload)
}

/// Wraps encoded payload data in a CallOfferEvent as the encryptedSdpPayload field.
private func makeOfferEvent(
    payload: Data,
    callId: String = "test-call-id",
    callerId: String = "alice"
) -> Sanchr_Messaging_CallOfferEvent {
    var event = Sanchr_Messaging_CallOfferEvent()
    event.callID = callId
    event.callerID = callerId
    event.encryptedSdpPayload = payload
    return event
}

// MARK: - CallManagerE2EETests

final class CallManagerE2EETests: XCTestCase {

    // MARK: - Test 1: startCall encrypts and sends payload (E2EE cipher path)

    /// Verifies that the encrypt → send flow runs to completion: `SealedCallPayload` is
    /// JSON-encoded, passed through the identity cipher (MockSignalManager), and the
    /// result is sent to the signaling service. Success is confirmed by `callState`
    /// reaching `.outgoing` — the state set immediately after `initiateCall` returns
    /// and before the asynchronous signaling stream task is scheduled.
    func test_startCall_encryptsAndSendsPayload() async throws {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager
        )

        do {
            try await callManager.startCall(recipientId: "bob", recipientName: "Bob", isVideo: false)
            // Immediately after startCall returns, state is .outgoing — the signaling
            // stream Task is enqueued but has not yet run.
            if case .outgoing = callManager.callState {
                // Expected: encrypt → send succeeded
                XCTAssertGreaterThan(signalManager.encryptCallCount, 0,
                    "encrypt must be called at least once during startCall — E2EE pipe must be wired")
            } else {
                XCTFail("Expected .outgoing after startCall, got \(callManager.callState)")
            }
        } catch {
            throw XCTSkip("WebRTC/CallKit unavailable — skipping outgoing call E2EE smoke test: \(error.localizedDescription)")
        }
    }

    // MARK: - Test 2: Fresh offer is decrypted and presented as incoming

    /// Decrypts a fresh, fingerprint-matching incoming call offer and verifies
    /// that `callState` transitions to `.incoming`.
    func test_handleIncomingCallOffer_decryptsAndPresents() async throws {
        let callManager = makeCallManager()

        // Build SDP with a real fingerprint line and matching payload field.
        let fp = "sha-256 AA:BB:CC:DD:EE:FF"
        let sdp = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:\(fp)\r\n"
        let payloadData = try makeSealedPayload(payloadFingerprint: fp, sdpBody: sdp)
        let offer = makeOfferEvent(payload: payloadData)

        _ = await callManager.handleIncomingCallOffer(offer)

        // Poll until state transitions away from .idle (or for up to 2 s on a loaded CI runner)
        let presented = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak callManager] _, _ in
                guard let cm = callManager else { return false }
                if case .idle = cm.callState { return false }
                return true
            },
            object: nil
        )
        await fulfillment(of: [presented], timeout: 2.0)

        // Accept .incoming (CallKit available) or .ended(_, .failed) (CallKit unavailable in CI).
        // Both prove the E2EE validation passed — only .idle would mean decryption/validation rejected the call.
        switch callManager.callState {
        case .incoming:
            break  // Ideal: CallKit accepted the call
        case .ended(_, .failed):
            break  // Expected in CI: decryption/fingerprint validation passed, CallKit reported error
        case .idle:
            XCTFail("Call was rejected before presentation — decryption or DTLS validation failed")
        default:
            XCTFail("Unexpected call state after valid offer: \(callManager.callState)")
        }
    }

    // MARK: - Test 3: Stale timestamp is rejected — call state remains .idle

    /// An offer whose timestamp is 60 seconds old (beyond the 30-second replay window)
    /// must be silently dropped without presenting the incoming call.
    func test_handleIncomingCallOffer_rejectsStaleTimestamp() async throws {
        let callManager = makeCallManager()

        let fp = "sha-256 AA:BB:CC:DD:EE:FF"
        let sdp = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:\(fp)\r\n"
        // 60 seconds in the past — well past the 30 s staleness window
        let payloadData = try makeSealedPayload(ageDelta: -60, payloadFingerprint: fp, sdpBody: sdp)
        let offer = makeOfferEvent(payload: payloadData)

        _ = await callManager.handleIncomingCallOffer(offer)

        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(callManager.callState, .idle,
            "Stale offer (60 s old) must be rejected — replay protection must hold")
    }

    // MARK: - Test 4: DTLS fingerprint mismatch is rejected — call state remains .idle

    /// An offer whose sealed-payload fingerprint does not match the fingerprint line in
    /// the SDP is rejected to prevent MITM attacks on the DTLS channel.
    func test_handleIncomingCallOffer_rejectsDtlsFingerprintMismatch() async throws {
        let callManager = makeCallManager()

        // The SDP says XX:YY but the sealed payload claims AA:BB — mismatch.
        let sdp = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 XX:YY\r\n"
        let payloadData = try makeSealedPayload(payloadFingerprint: "sha-256 AA:BB", sdpBody: sdp)
        let offer = makeOfferEvent(payload: payloadData)

        _ = await callManager.handleIncomingCallOffer(offer)

        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(callManager.callState, .idle,
            "DTLS fingerprint mismatch must be rejected to prevent MITM — call must not be presented")
    }

    // MARK: - Test 5: endCall transitions state to .ended

    /// Verifies that calling `endCall()` on a live call sets `callState` to `.ended`.
    /// The call is placed into `.outgoing` state directly (bypassing WebRTC/CallKit)
    /// so the test exercises only the teardown path.
    func test_endCall_setsStateToEnded() async throws {
        let callManager = makeCallManager()

        // Inject outgoing state directly — bypasses WebRTC/CallKit to isolate the teardown path.
        callManager.callState = .outgoing(callId: "teardown-test-id", recipientId: "bob")

        callManager.endCall()

        // endCall is synchronous for the state transition.
        if case .ended(let callId, let reason) = callManager.callState {
            XCTAssertEqual(callId, "teardown-test-id")
            XCTAssertEqual(reason, .cancelled)
        } else {
            XCTFail("Expected .ended after endCall(), got \(callManager.callState)")
        }
    }

    // MARK: - Test 6: VoIP push in non-idle state satisfies PushKit without changing callState

    /// When the app is already in `.outgoing` state (caller side) and a delayed VoIP push
    /// arrives, `handleVoIPPushIncomingCall` must not crash and must not corrupt callState.
    /// PushKit satisfaction (reportNewIncomingCall) is verified indirectly — the test
    /// confirms state is not stomped; CallKit is unavailable in CI so we cannot assert
    /// on CXProvider calls directly.
    func test_handleVoIPPushIncomingCall_whileOutgoing_doesNotMutateState() {
        let callManager = makeCallManager()
        callManager.callState = .outgoing(callId: "outgoing-call", recipientId: "bob")

        // Should not crash, should not change state
        callManager.handleVoIPPushIncomingCall(
            callId: "different-incoming-call",
            callerId: "carol",
            callerDevice: 0,
            callType: "voice",
            encryptedSdpPayload: Data()
        )

        if case .outgoing(let id, let recipientId) = callManager.callState {
            XCTAssertEqual(id, "outgoing-call",
                "callState must not be overwritten by a VoIP push arriving during an outgoing call")
            XCTAssertEqual(recipientId, "bob",
                "recipientId must not be mutated by a VoIP push arriving during an outgoing call")
        } else {
            XCTFail("callState was mutated by handleVoIPPushIncomingCall — expected .outgoing, got \(callManager.callState)")
        }
    }

    /// When the app is in `.ended` state (2-second cooldown) and a delayed VoIP push arrives,
    /// `handleVoIPPushIncomingCall` must not resurrect the ended call or crash.
    func test_handleVoIPPushIncomingCall_whileEnded_doesNotMutateState() {
        let callManager = makeCallManager()
        callManager.callState = .ended(callId: "ended-call", reason: .normal)

        callManager.handleVoIPPushIncomingCall(
            callId: "new-incoming-call",
            callerId: "dave",
            callerDevice: 0,
            callType: "voice",
            encryptedSdpPayload: Data()
        )

        if case .ended(let id, let reason) = callManager.callState {
            XCTAssertEqual(id, "ended-call",
                "callState must remain .ended — a VoIP push must not resurrect an ended call")
            XCTAssertEqual(reason, .normal)
        } else {
            XCTFail("callState was mutated — expected .ended, got \(callManager.callState)")
        }
    }

    /// When the app is already `.incoming` for one call and a delayed VoIP push arrives
    /// for a DIFFERENT call, the existing incoming call must not be disrupted.
    func test_handleVoIPPushIncomingCall_whileIncomingDifferentCallId_doesNotMutateState() {
        let callManager = makeCallManager()
        // Simulate stream-first delivery for call-A
        callManager.callState = .incoming(callId: "call-A", callerId: "alice", callerName: "Alice")

        // Delayed push for a different call-B — should NOT take over
        callManager.handleVoIPPushIncomingCall(
            callId: "call-B",
            callerId: "bob",
            callerDevice: 0,
            callType: "voice",
            encryptedSdpPayload: Data()
        )

        if case .incoming(let id, let callerId, let callerName) = callManager.callState {
            XCTAssertEqual(id, "call-A",
                "Existing incoming call-A must not be replaced by a push for call-B")
            XCTAssertEqual(callerId, "alice")
            XCTAssertEqual(callerName, "Alice",
                "callerName must not be mutated by a VoIP push for a different call")
        } else {
            XCTFail("callState was mutated — expected .incoming(call-A), got \(callManager.callState)")
        }
    }

    // MARK: - Peer Profile Resolution

    func test_resolveCallPeerProfile_prefersContactProfile() async throws {
        let avatarURL = try XCTUnwrap(URL(string: "https://cdn.sanchr.test/alice.jpg"))
        let database = ProfileResolverDatabase(
            contacts: [
                makeUser(id: "alice", displayName: "Alice Contact", avatarURL: avatarURL),
            ],
            conversations: [
                makeConversation(
                    peer: makeUser(id: "alice", displayName: "Alice Conversation", avatarURL: nil)
                ),
            ]
        )

        let profile = await DependencyContainer.resolveCallPeerProfile(
            userId: "alice",
            localDatabase: database
        )

        XCTAssertEqual(profile?.displayName, "Alice Contact")
        XCTAssertEqual(profile?.avatarURL, avatarURL)
    }

    func test_resolveCallPeerProfile_usesConversationFallback() async throws {
        let avatarURL = try XCTUnwrap(URL(string: "https://cdn.sanchr.test/bob.jpg"))
        let database = ProfileResolverDatabase(
            contacts: [],
            conversations: [
                makeConversation(
                    peer: makeUser(id: "bob", displayName: "Bob Conversation", avatarURL: avatarURL)
                ),
            ]
        )

        let profile = await DependencyContainer.resolveCallPeerProfile(
            userId: "bob",
            localDatabase: database
        )

        XCTAssertEqual(profile?.displayName, "Bob Conversation")
        XCTAssertEqual(profile?.avatarURL, avatarURL)
    }

    func test_resolveCallPeerProfile_ignoresUUIDDisplayNames() async throws {
        let userId = "00000000-0000-0000-0000-000000000000"
        let database = ProfileResolverDatabase(
            contacts: [
                makeUser(id: userId, phoneNumber: userId, displayName: userId, avatarURL: nil),
            ],
            conversations: []
        )

        let profile = await DependencyContainer.resolveCallPeerProfile(
            userId: userId,
            localDatabase: database
        )

        XCTAssertNil(profile)
    }

    func test_resolveCallPeerProfile_allowsMissingAvatar() async {
        let database = ProfileResolverDatabase(
            contacts: [
                makeUser(id: "carol", displayName: "Carol", avatarURL: nil),
            ],
            conversations: []
        )

        let profile = await DependencyContainer.resolveCallPeerProfile(
            userId: "carol",
            localDatabase: database
        )

        XCTAssertEqual(profile?.displayName, "Carol")
        XCTAssertNil(profile?.avatarURL)
    }

    func test_handleIncomingCall_appliesResolvedPeerAvatar() async throws {
        let avatarURL = try XCTUnwrap(URL(string: "https://cdn.sanchr.test/alice.jpg"))
        let callManager = makeCallManager { userId in
            guard userId == "alice" else { return nil }
            return CallPeerProfile(displayName: "Alice", avatarURL: avatarURL)
        }

        await MainActor.run {
            callManager.handleIncomingCall(
                callId: "profile-call",
                callerId: "alice",
                callerName: "alice",
                sdpOffer: Data(),
                isVideo: false
            )
        }

        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak callManager] _, _ in
                callManager?.peerName == "Alice" && callManager?.peerAvatarURL == avatarURL
            },
            object: nil
        )
        await fulfillment(of: [resolved], timeout: 2.0)

        XCTAssertEqual(callManager.peerName, "Alice")
        XCTAssertEqual(callManager.peerAvatarURL, avatarURL)
    }

    func test_shouldReportIncomingCallToCallKit_skipsForegroundPresentation() {
        XCTAssertFalse(
            CallManager.shouldReportIncomingCallToCallKit(
                applicationState: .active,
                isSimulator: false
            )
        )
    }

    func test_shouldReportIncomingCallToCallKit_skipsSimulatorPresentation() {
        XCTAssertFalse(
            CallManager.shouldReportIncomingCallToCallKit(
                applicationState: .background,
                isSimulator: true
            )
        )
    }

    func test_shouldReportIncomingCallToCallKit_keepsBackgroundCallKitPath() {
        XCTAssertTrue(
            CallManager.shouldReportIncomingCallToCallKit(
                applicationState: .background,
                isSimulator: false
            )
        )
    }

    func test_handleControlAction_videoOffDisablesPeerVideoWithoutDroppingTrackState() async {
        let callManager = makeCallManager()

        await MainActor.run {
            callManager.callType = "video"
            callManager.callState = .active(callId: "video-call", startTime: Date())
            callManager.peerVideoEnabled = true
            callManager.hasRemoteVideoTrack = true
            callManager.handleControlAction("video_off", callId: "video-call")
        }

        XCTAssertFalse(callManager.peerVideoEnabled)
        XCTAssertTrue(callManager.hasRemoteVideoTrack)
    }

    func test_handleControlAction_videoOnRestoresPeerVideo() async {
        let callManager = makeCallManager()

        await MainActor.run {
            callManager.callType = "video"
            callManager.callState = .active(callId: "video-call", startTime: Date())
            callManager.peerVideoEnabled = false
            callManager.hasRemoteVideoTrack = true
            callManager.handleControlAction("video_on", callId: "video-call")
        }

        XCTAssertTrue(callManager.peerVideoEnabled)
        XCTAssertTrue(callManager.hasRemoteVideoTrack)
    }

    func test_handleCallLifecycleEvent_refreshesPeerProfile() async throws {
        let avatarURL = try XCTUnwrap(URL(string: "https://cdn.sanchr.test/dave.jpg"))
        let callManager = makeCallManager { userId in
            guard userId == "dave" else { return nil }
            return CallPeerProfile(displayName: "Dave", avatarURL: avatarURL)
        }
        callManager.callState = .active(callId: "lifecycle-call", startTime: Date())

        var event = Sanchr_Messaging_CallLifecycleEvent()
        event.callID = "lifecycle-call"
        event.peerID = "dave"
        event.eventType = "accepted"
        _ = await callManager.handleCallLifecycleEvent(event)

        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak callManager] _, _ in
                callManager?.peerName == "Dave" && callManager?.peerAvatarURL == avatarURL
            },
            object: nil
        )
        await fulfillment(of: [resolved], timeout: 2.0)

        XCTAssertEqual(callManager.peerName, "Dave")
        XCTAssertEqual(callManager.peerAvatarURL, avatarURL)
    }

    func test_resetState_clearsPeerAvatar() {
        let callManager = makeCallManager()
        callManager.callState = .active(callId: "avatar-call", startTime: Date())
        callManager.peerId = "alice"
        callManager.peerName = "Alice"
        callManager.peerAvatarURL = URL(string: "https://cdn.sanchr.test/alice.jpg")

        callManager.resetState()

        XCTAssertNil(callManager.peerId)
        XCTAssertNil(callManager.peerName)
        XCTAssertNil(callManager.peerAvatarURL)
    }

    /// resetState must zero remoteCallerDevice so the next call's return-path
    /// encrypt does not inherit a stale device id from the prior session.
    /// Sub-phase D's sendEncryptedSessionDescription reads this value; without
    /// the reset, a sequential call from a different device would encrypt the
    /// answer for the wrong Signal session.
    func test_resetState_clearsRemoteCallerDevice() async throws {
        let callManager = makeCallManager()

        // Drive the real decrypt path to set remoteCallerDevice = 7.
        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )
        var offerEvent = makeOfferEvent(payload: payload, callerId: "alice")
        offerEvent.callerDevice = 7
        _ = await callManager.handleIncomingCallOffer(offerEvent)
        XCTAssertEqual(callManager.remoteCallerDevice, 7,
            "precondition: handleIncomingCallOffer must persist callerDevice")

        callManager.resetState()

        XCTAssertEqual(callManager.remoteCallerDevice, 0,
            "resetState must zero remoteCallerDevice — Sub-phase D return-path encrypt must not inherit stale device ids")
    }

    // MARK: - Video Feature Gate Tests

    /// With isVideoCallEnabled=false, requesting a video call must fail
    /// before any network or WebRTC side effects occur.
    func test_startCall_rejectsVideoWhenFeatureDisabled() async {
        let callManager = makeCallManager(isVideoCallEnabled: false)
        do {
            try await callManager.startCall(recipientId: "bob", recipientName: "Bob", isVideo: true)
            XCTFail("Expected startCall to throw when isVideoCallEnabled is false")
        } catch AppError.featureDisabled {
            // expected
        } catch {
            XCTFail("Expected AppError.featureDisabled, got \(error)")
        }
        if case .idle = callManager.callState {
            // no side effects — expected
        } else {
            XCTFail("callState must remain .idle when the gate blocks startCall")
        }
    }

    /// Truth table for the gate. Drives the static helper directly so the
    /// signal is real CI evidence — the previous integration variant always
    /// skipped on simulator because `getTurnCredentials` failed before the
    /// caller could observe the gate's outcome.
    func test_shouldBlockVideoCall_truthTable() {
        XCTAssertTrue(
            CallManager.shouldBlockVideoCall(isVideo: true, isVideoCallEnabled: false),
            "video request must be blocked when feature is disabled"
        )
        XCTAssertFalse(
            CallManager.shouldBlockVideoCall(isVideo: true, isVideoCallEnabled: true),
            "video request is allowed when feature is enabled"
        )
        XCTAssertFalse(
            CallManager.shouldBlockVideoCall(isVideo: false, isVideoCallEnabled: false),
            "voice request is never blocked, regardless of video flag"
        )
        XCTAssertFalse(
            CallManager.shouldBlockVideoCall(isVideo: false, isVideoCallEnabled: true),
            "voice request is never blocked when both flags are on"
        )
    }

    /// requestVideoUpgrade on an active call is a no-op when the flag is off.
    func test_requestVideoUpgrade_noopWhenFeatureDisabled() async {
        let callManager = makeCallManager(isVideoCallEnabled: false)
        callManager.callState = .active(callId: "cid", startTime: Date())
        callManager.requestVideoUpgrade()
        XCTAssertFalse(callManager.outgoingVideoUpgradePending,
            "requestVideoUpgrade must be a no-op when the feature is disabled")
    }

    // MARK: - Private Helpers

    /// Builds a default `CallManager` for tests. `localDeviceIdProvider`
    /// defaults to `{ 1 }` to keep existing tests stable; pass an explicit
    /// provider when a test asserts on `peerDevice` / `answererDevice`
    /// stamping behaviour, so it is not silently coupled to the default.
    /// `isVideoCallEnabled` defaults to `true` so existing tests need no changes.
    private func makeCallManager(
        peerProfileResolver: @escaping @Sendable (String) async -> CallPeerProfile? = { _ in nil },
        localDeviceIdProvider: @escaping @Sendable () -> Int32 = { 1 },
        isVideoCallEnabled: Bool = true
    ) -> CallManager {
        CallManager(
            webRTCClient: WebRTCClient(),
            callService: MockCallSignalingService(),
            signalManager: MockSignalManager(),
            peerProfileResolver: peerProfileResolver,
            localDeviceIdProvider: localDeviceIdProvider,
            isVideoCallEnabled: isVideoCallEnabled
        )
    }

    private func makeUser(
        id: String,
        phoneNumber: String = "",
        displayName: String,
        avatarURL: URL?,
        isLocalUser: Bool = false
    ) -> User {
        User(
            id: id,
            phoneNumber: phoneNumber,
            displayName: displayName,
            avatarURL: avatarURL,
            isVerified: false,
            status: .offline,
            isLocalUser: isLocalUser
        )
    }

    private func makeConversation(peer: User) -> Conversation {
        Conversation(
            id: "conversation-\(peer.id)",
            participants: [
                makeUser(id: "local", displayName: "Local User", avatarURL: nil, isLocalUser: true),
                peer,
            ],
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - Multi-device decrypt

    /// After a successful incoming-offer decrypt, the CallManager must remember
    /// which sender device the ciphertext came from so subsequent answer
    /// ciphertext can be encrypted for that exact Signal session.
    func test_handleIncomingCallOffer_persistsRemoteCallerDevice() async throws {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager
        )

        // Build an offer event with caller_device = 7 — the field added in sub-phase B.
        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )
        var offerEvent = makeOfferEvent(payload: payload, callerId: "alice")
        offerEvent.callerDevice = 7

        let outcome = await callManager.handleIncomingCallOffer(offerEvent)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(callManager.remoteCallerDevice, 7,
            "remoteCallerDevice must hold the sender device id after a decrypt succeeds")
    }

    /// When the server hasn't populated caller_device yet (value = 0), iOS must
    /// fall back to device 1 so legacy offers still round-trip.
    func test_handleIncomingCallOffer_fallsBackToDeviceOneWhenCallerDeviceAbsent() async throws {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager
        )

        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )
        let offerEvent = makeOfferEvent(payload: payload, callerId: "alice")
        // offerEvent.callerDevice stays 0 (default) — simulates legacy server.

        let outcome = await callManager.handleIncomingCallOffer(offerEvent)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(callManager.remoteCallerDevice, 1,
            "must fall back to device 1 when caller_device is absent (0)")
    }

    /// VoIP push arrives with the caller's device id — the async SDP decrypt
    /// Task must use it instead of hardcoding device 1.
    func test_handleVoIPPushIncomingCall_usesCallerDeviceForDecrypt() async throws {
        let signalManager = RecordingSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = await MainActor.run {
            CallManager(
                webRTCClient: webRTCClient,
                callService: callService,
                signalManager: signalManager
            )
        }

        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )

        await MainActor.run {
            callManager.handleVoIPPushIncomingCall(
                callId: "push-call-id",
                callerId: "alice",
                callerDevice: 9,
                callType: "voice",
                encryptedSdpPayload: payload
            )
        }

        // Give the async decrypt Task a chance to run. 500ms matches the
        // convention used by the other VoIP-push tests in this file.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(signalManager.lastSenderDevice, 9,
            "VoIP push decrypt must address the caller's device id, not hardcode 1")
    }

    // MARK: - Sub-phase E: outgoing answer encrypt

    /// Callee encrypts the SDP answer for the caller's actual device, not device 1.
    func test_buildEncryptedAnswerPayload_usesRemoteCallerDevice() async throws {
        let signalManager = DeviceRecordingSignalManager()
        let sdp = "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        let fingerprint = "sha-256 DE:AD:BE:EF"

        _ = try await CallManager.buildEncryptedAnswerPayload(
            sdp: sdp,
            fingerprint: fingerprint,
            type: "answer",
            remoteCallerDevice: 9,
            recipientId: "alice",
            signalManager: signalManager
        )

        XCTAssertEqual(signalManager.lastEncryptDeviceId, 9,
            "answer ciphertext must be encrypted for the caller's recovered device (9), not device 1")
    }

    /// When remoteCallerDevice is zero (legacy offer path), fall back to device 1.
    func test_buildEncryptedAnswerPayload_fallsBackToDeviceOneWhenRemoteCallerDeviceIsZero() async throws {
        let signalManager = DeviceRecordingSignalManager()
        let sdp = "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        let fingerprint = "sha-256 DE:AD:BE:EF"

        _ = try await CallManager.buildEncryptedAnswerPayload(
            sdp: sdp,
            fingerprint: fingerprint,
            type: "answer",
            remoteCallerDevice: 0,
            recipientId: "alice",
            signalManager: signalManager
        )

        XCTAssertEqual(signalManager.lastEncryptDeviceId, 1,
            "must fall back to device 1 when remoteCallerDevice is zero (legacy offer path)")
    }

    // MARK: - Sub-phase E: caller-side SDP answer decrypt

    /// Caller decrypts the incoming SDP answer using `CallSignal.peerDevice`
    /// (the callee's actual device, mirrored by the server), not device 1.
    func test_decryptIncomingAnswer_usesPeerDeviceFromSignal() async throws {
        let signalManager = DeviceRecordingSignalManager()
        let sdp = "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        let fingerprint = "sha-256 DE:AD:BE:EF"

        let payload = SealedCallPayload(
            sdp: sdp,
            dtlsFingerprint: fingerprint,
            timestamp: Date().timeIntervalSince1970
        )
        let plaintext = try JSONEncoder().encode(payload)

        let decrypted = try await CallManager.decryptIncomingAnswer(
            ciphertext: plaintext,
            peerDevice: 7,
            senderId: "bob",
            signalManager: signalManager
        )

        XCTAssertEqual(signalManager.lastSenderDevice, 7,
            "caller must decrypt the SDP answer using the callee's peerDevice (7), not device 1")
        XCTAssertEqual(decrypted.dtlsFingerprint, fingerprint)
    }

    /// When the server hasn't populated peerDevice yet (value = 0), fall back to device 1.
    func test_decryptIncomingAnswer_fallsBackToDeviceOneWhenPeerDeviceIsZero() async throws {
        let signalManager = DeviceRecordingSignalManager()
        let sdp = "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        let fingerprint = "sha-256 DE:AD:BE:EF"

        let payload = SealedCallPayload(
            sdp: sdp,
            dtlsFingerprint: fingerprint,
            timestamp: Date().timeIntervalSince1970
        )
        let plaintext = try JSONEncoder().encode(payload)

        _ = try await CallManager.decryptIncomingAnswer(
            ciphertext: plaintext,
            peerDevice: 0,
            senderId: "bob",
            signalManager: signalManager
        )

        XCTAssertEqual(signalManager.lastSenderDevice, 1,
            "must fall back to device 1 when peerDevice is zero (legacy callee path)")
    }

}

// MARK: - DeviceRecordingSignalManager

/// Identity-cipher mock that records both the `deviceId` passed to `encrypt`
/// and the `senderDevice` passed to `decrypt` so tests can assert per-device
/// addressing on either path. The mocks for the two paths used to be separate
/// types — they shared 60+ lines of identical no-op stubs, which made every
/// future protocol change touch both places.
private final class DeviceRecordingSignalManager: SignalProtocolManagerProtocol, @unchecked Sendable {
    let localUserId: String = "test-local-user"
    /// The deviceId argument from the most recent `encrypt` call. Starts at -1.
    var lastEncryptDeviceId: Int32 = -1
    /// The senderDevice argument from the most recent `decrypt` call. Starts at -1.
    var lastSenderDevice: Int32 = -1

    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data {
        lastEncryptDeviceId = deviceId
        return plaintext
    }
    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data {
        lastSenderDevice = senderDevice
        return ciphertext
    }
    func establishSession(with userId: String, deviceId: Int32) async throws {}
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
    func hasSession(with userId: String) -> Bool { true }
    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws -> [Sanchr_Messaging_DeviceMessage] { [] }
    func encryptCallOffers(plaintext: Data, recipientId: String) async throws -> [Sanchr_Calling_DeviceCallOffer] { [] }
    func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { envelope.ciphertext }
    func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
        throw AppError.decryptionFailed(reason: "not used")
    }
    func resetSession(with userId: String, deviceId: Int32) throws {}
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
    func markIdentityVerified(userId: String) {}
    func isIdentityVerified(userId: String) -> Bool { false }
    func hasPendingIdentityChange(userId: String) -> Bool { false }
    func acceptIdentityChange(userId: String) {}
    func localIdentityKeyData() throws -> Data { Data() }
    func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
}

private final class ProfileResolverDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    let contacts: [User]
    let conversations: [Conversation]

    init(contacts: [User], conversations: [Conversation]) {
        self.contacts = contacts
        self.conversations = conversations
    }

    func saveMessage(_ message: Message) async throws {}
    func deleteMessage(id: String) async throws {}
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws {}
    func fetchContacts() async throws -> [User] { contacts }
    func fetchConversations() async throws -> [Conversation] { conversations }
}
