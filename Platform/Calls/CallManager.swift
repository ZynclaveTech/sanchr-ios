import AVFoundation
import CallKit
import Foundation
import GRPC
import WebRTC
import SanchrShared

protocol CallEventRouting: AnyObject, Sendable {
    func handleIncomingCallOffer(_ offer: Sanchr_Messaging_CallOfferEvent)
    func handleCallLifecycleEvent(_ event: Sanchr_Messaging_CallLifecycleEvent)
    func resetState()
}

private struct SendableAnswerAction: @unchecked Sendable {
    let action: CXAnswerCallAction
}

// MARK: - Call State

enum CallState: Equatable, Sendable {
    case idle
    case outgoing(callId: String, recipientId: String)
    case incoming(callId: String, callerId: String, callerName: String)
    case ringing(callId: String)
    case active(callId: String, startTime: Date)
    case reconnecting(callId: String)
    case ended(callId: String, reason: EndReason)

    enum EndReason: Equatable, Sendable {
        case normal
        case busy
        case declined
        case failed
        case timeout
        case networkError
    }

    var callId: String? {
        switch self {
        case .idle: nil
        case .outgoing(let id, _): id
        case .incoming(let id, _, _): id
        case .ringing(let id): id
        case .active(let id, _): id
        case .reconnecting(let id): id
        case .ended(let id, _): id
        }
    }
}

// MARK: - CallManager

@Observable
final class CallManager: NSObject, CallEventRouting, @unchecked Sendable {

    // MARK: - Observable State

    var callState: CallState = .idle
    var isMuted: Bool = false
    var isSpeakerOn: Bool = false
    var isVideoEnabled: Bool = false
    var callDuration: TimeInterval = 0
    var callType: String = "voice"
    var peerId: String?
    var peerName: String?
    var currentVideoFilter: VideoFilter = .none

    // MARK: - Dependencies

    private let webRTCClient: WebRTCClient
    private let callService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol
    private let provider: CXProvider
    private let callController: CXCallController
    private let signalManager: SignalProtocolManagerProtocol

    // MARK: - Internal State

    private var callUUID: UUID?
    private var pendingSdpOffer: Data?
    private var paddingManager = CallDurationPaddingManager()
    private var callStartTime: Date?
    private var durationTimer: Timer?
    private var signalingTask: Task<Void, Never>?

    /// Continuation for sending signals through the bidirectional stream.
    private var outboundContinuation: AsyncStream<Sanchr_Calling_CallSignal>.Continuation?

    // MARK: - Init

    init(
        webRTCClient: WebRTCClient,
        callService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol,
        signalManager: SignalProtocolManagerProtocol
    ) {
        self.webRTCClient = webRTCClient
        self.callService = callService
        self.signalManager = signalManager

        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.ringtoneSound = nil
        config.iconTemplateImageData = nil
        self.provider = CXProvider(configuration: config)
        self.callController = CXCallController()

        super.init()
        provider.setDelegate(self, queue: .main)
        webRTCClient.delegate = self
    }

    // MARK: - Outgoing Call

    /// Initiates an outgoing call to the given recipient.
    /// 1. Fetch TURN credentials from the server
    /// 2. Configure WebRTC with TURN/STUN servers
    /// 3. Start local media (audio + optional video)
    /// 4. Create SDP offer
    /// 5. Send the offer to the backend via gRPC initiateCall
    /// 6. Report the outgoing call to CallKit
    /// 7. Open the bidirectional signaling stream
    func startCall(recipientId: String, recipientName: String, isVideo: Bool) async throws {
        guard case .idle = callState else {
            throw AppError.callAlreadyInProgress
        }

        SanchrLogger.calls.info("Starting \(isVideo ? "video" : "voice") call to \(recipientId)")
        self.callType = isVideo ? "video" : "voice"
        self.isVideoEnabled = isVideo

        // 1. Fetch TURN credentials
        let turnCredentials = try await callService.getTurnCredentials(
            Sanchr_Calling_GetTurnCredentialsRequest())
        let iceServers = buildIceServers(from: turnCredentials)

        // 2. Configure WebRTC
        webRTCClient.configure(iceServers: iceServers)

        // 3. Start local media
        webRTCClient.startLocalMedia(isVideo: isVideo)

        // 4. Create SDP offer
        let offer = try await webRTCClient.createOffer()
        try await webRTCClient.setLocalDescription(offer)

        // 5. Encrypt offer for E2EE
        guard let fingerprint = WebRTCClient.extractDtlsFingerprint(from: offer) else {
            throw AppError.callConnectionFailed
        }
        let payload = SealedCallPayload(
            sdp: offer.sdp,
            dtlsFingerprint: fingerprint,
            timestamp: Date().timeIntervalSince1970
        )
        let payloadData = try JSONEncoder().encode(payload)
        // FIXME: senderDevice hard-coded to 1 — multi-device accounts will not receive calls on other devices.
        let encryptedPayload = try await signalManager.encrypt(
            plaintext: payloadData, for: recipientId, deviceId: 1)
        // NOTE: delivery_token (sealed-sender call routing) is not yet implemented on the server.
        // sanchr-call routes via recipient_id and ignores the token field. Do not acquire a token
        // here — the acquisition is a blocking gRPC round-trip that fails and kills the call setup.

        // 6. Send the encrypted offer to the server
        var callOffer = Sanchr_Calling_CallOffer()
        callOffer.recipientID = recipientId
        callOffer.callType = isVideo ? "video" : "voice"
        callOffer.encryptedSdpPayload = encryptedPayload

        let response = try await callService.initiateCall(callOffer)
        let callId = response.callID

        SanchrLogger.calls.info("Call initiated, callId=\(callId), status=\(response.status)")

        if response.status == "busy" {
            callState = .ended(callId: callId, reason: .busy)
            webRTCClient.close()
            return
        }

        callState = .outgoing(callId: callId, recipientId: recipientId)
        peerId = recipientId
        peerName = recipientName

        // 6. Report to CallKit
        let uuid = UUID()
        self.callUUID = uuid

        let handle = CXHandle(type: .generic, value: recipientId)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = isVideo
        startAction.contactIdentifier = recipientName
        let transaction = CXTransaction(action: startAction)
        try await callController.request(transaction)

        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())

        // 7. Open bidirectional signaling stream
        openSignalingStream(callId: callId)
    }

    // MARK: - Incoming Call

    /// Called when a push notification or signaling message delivers an incoming call.
    func handleIncomingCall(
        callId: String, callerId: String, callerName: String, sdpOffer: Data, isVideo: Bool
    ) {
        SanchrLogger.calls.info(
            "Incoming \(isVideo ? "video" : "voice") call from \(callerName) [\(callId)]")

        self.callType = isVideo ? "video" : "voice"
        self.isVideoEnabled = isVideo
        self.pendingSdpOffer = sdpOffer
        self.peerId = callerId
        self.peerName = callerName

        let uuid = UUID()
        self.callUUID = uuid
        callState = .incoming(callId: callId, callerId: callerId, callerName: callerName)

        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.hasVideo = isVideo
        update.supportsGrouping = false
        update.supportsHolding = true
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.remoteHandle = CXHandle(type: .generic, value: callerId)

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                SanchrLogger.calls.error(
                    "Failed to report incoming call: \(error.localizedDescription)")
                self?.callState = .ended(callId: callId, reason: .failed)
            }
        }
    }

    /// Called from the PushKit delegate when a VoIP push is received for an incoming call.
    ///
    /// PushKit requires `CXProvider.reportNewIncomingCall` to be called synchronously within
    /// this callback (before the function returns).  SDP decryption is deferred to a background
    /// Task and the `pendingSdpOffer` is populated asynchronously; `answerCall()` waits for it.
    ///
    /// - Parameters:
    ///   - callId: The call identifier from the push payload.
    ///   - callerId: The caller's user ID (used as display name placeholder until contacts sync).
    ///   - callType: "voice" or "video".
    ///   - encryptedSdpPayload: Raw bytes of the Signal-encrypted SDP offer.
    func handleVoIPPushIncomingCall(
        callId: String,
        callerId: String,
        callType: String,
        encryptedSdpPayload: Data
    ) {
        guard case .idle = callState else {
            // PushKit REQUIRES reportNewIncomingCall to be called synchronously on EVERY
            // return path — including state mismatches.  Returning without calling it causes
            // iOS to kill the app immediately with no grace period.
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: callerId)
            update.localizedCallerName = callerId
            update.hasVideo = callType == "video"

            if case .incoming(let existingId, _, _) = callState,
               existingId == callId,
               let existingUUID = callUUID
            {
                // Same call already reported via MessageStream.  Re-report with the same
                // UUID so CallKit updates the existing entry instead of creating a duplicate.
                provider.reportNewIncomingCall(with: existingUUID, update: update) { _ in }
                SanchrLogger.calls.info(
                    "VoIP push: refreshed CallKit for call \(callId) (stream arrived first)")
            } else {
                // Busy / active / ended / different callId.  PushKit still requires
                // reportNewIncomingCall.  Use a throwaway UUID and immediately end it so
                // no phantom entry lingers in the CallKit call list.
                // (Apple explicitly endorses this pattern in the PushKit documentation.)
                let throwawayUUID = UUID()
                provider.reportNewIncomingCall(with: throwawayUUID, update: update) { [weak self] _ in
                    self?.provider.reportCall(with: throwawayUUID, endedAt: Date(), reason: .failed)
                }
                SanchrLogger.calls.warning(
                    "VoIP push: satisfied PushKit via throwaway UUID — state mismatch for call \(callId)")
            }
            return
        }

        SanchrLogger.calls.info("VoIP push: incoming \(callType) call \(callId) from \(callerId)")

        self.callType = callType
        self.isVideoEnabled = callType == "video"
        self.peerId = callerId
        self.peerName = callerId  // placeholder; updated when contacts load

        let uuid = UUID()
        self.callUUID = uuid
        callState = .incoming(callId: callId, callerId: callerId, callerName: callerId)

        let update = CXCallUpdate()
        update.localizedCallerName = callerId
        update.hasVideo = callType == "video"
        update.supportsGrouping = false
        update.supportsHolding = true
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.remoteHandle = CXHandle(type: .generic, value: callerId)

        // MUST be called synchronously within the PushKit callback.
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                SanchrLogger.calls.error(
                    "VoIP push: failed to report call \(callId) to CallKit: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.endCallInternal(callId: callId, reason: .failed)
                }
            }
        }

        // Decrypt the SDP offer asynchronously. answerCall() will wait for this to
        // complete (max 5 seconds) before proceeding.
        // If the SDP was absent from the push (payload too large for APNs), skip decryption
        // here — the SDP will arrive via MessageStream replay and handleIncomingCallOffer
        // will populate pendingSdpOffer when it sees we're already in incoming state.
        guard !encryptedSdpPayload.isEmpty else {
            SanchrLogger.calls.info(
                "VoIP push: no SDP in payload for call \(callId) — waiting for stream delivery")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // FIXME: senderDevice hard-coded to 1 — multi-device accounts not handled.
                let plaintext = try await self.signalManager.decrypt(
                    ciphertext: encryptedSdpPayload,
                    from: callerId,
                    senderDevice: 1
                )
                let sealedPayload = try JSONDecoder().decode(SealedCallPayload.self, from: plaintext)

                // VoIP pushes can be delayed by APNs; allow a 120-second window.
                let age = abs(Date().timeIntervalSince1970 - sealedPayload.timestamp)
                guard age <= 120 else {
                    SanchrLogger.calls.error(
                        "VoIP push: rejecting stale SDP for call \(callId) (age=\(Int(age))s)")
                    endCallInternal(callId: callId, reason: .failed)
                    return
                }

                let offerDesc = RTCSessionDescription(type: .offer, sdp: sealedPayload.sdp)
                guard let sdpFingerprint = WebRTCClient.extractDtlsFingerprint(from: offerDesc),
                      sdpFingerprint == sealedPayload.dtlsFingerprint
                else {
                    SanchrLogger.calls.error(
                        "VoIP push: DTLS fingerprint mismatch for call \(callId)")
                    endCallInternal(callId: callId, reason: .failed)
                    return
                }

                self.pendingSdpOffer = Data(sealedPayload.sdp.utf8)
                SanchrLogger.calls.info(
                    "VoIP push: SDP decrypted and stored for call \(callId)")
            } catch {
                SanchrLogger.calls.error(
                    "VoIP push: SDP decryption failed for call \(callId): \(error.localizedDescription)")
                // Don't end the call — give the user a chance to answer.
                // answerCall() will fail gracefully if SDP is still nil.
            }
        }
    }

    /// Answers an incoming call. Called from CallKit delegate or directly.
    func answerCall() async throws {
        guard case .incoming(let callId, let callerId, _) = callState else {
            SanchrLogger.calls.error("answerCall: not in incoming state")
            return
        }

        // For VoIP push calls the SDP is decrypted asynchronously; wait up to 5s.
        var sdpData: Data? = pendingSdpOffer
        if sdpData == nil {
            SanchrLogger.calls.info("answerCall: waiting for VoIP push SDP decryption...")
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(500))
                if let offer = pendingSdpOffer {
                    sdpData = offer
                    break
                }
            }
        }
        guard let sdpData else {
            SanchrLogger.calls.error("answerCall: SDP offer unavailable after 5s wait")
            throw AppError.callConnectionFailed
        }

        SanchrLogger.calls.info("Answering call \(callId)")

        // 1. Fetch TURN credentials
        let turnCredentials = try await callService.getTurnCredentials(
            Sanchr_Calling_GetTurnCredentialsRequest())
        let iceServers = buildIceServers(from: turnCredentials)

        // 2. Configure WebRTC
        webRTCClient.configure(iceServers: iceServers)

        // 3. Set remote SDP from the incoming offer
        let sdpString = String(data: sdpData, encoding: .utf8) ?? ""
        let remoteDescription = RTCSessionDescription(type: .offer, sdp: sdpString)
        try await webRTCClient.setRemoteDescription(remoteDescription)

        // 4. Start local media
        let isVideo = callType == "video"
        webRTCClient.startLocalMedia(isVideo: isVideo)

        // 5. Create SDP answer
        let answer = try await webRTCClient.createAnswer()
        try await webRTCClient.setLocalDescription(answer)

        // 6. Open signaling stream and send encrypted answer
        openSignalingStream(callId: callId)

        guard let answerFingerprint = WebRTCClient.extractDtlsFingerprint(from: answer) else {
            throw AppError.callConnectionFailed
        }
        let answerPayload = SealedCallPayload(
            sdp: answer.sdp,
            dtlsFingerprint: answerFingerprint,
            timestamp: Date().timeIntervalSince1970
        )
        let answerPayloadData = try JSONEncoder().encode(answerPayload)
        // FIXME: senderDevice hard-coded to 1 — multi-device accounts will not receive calls on other devices.
        let encryptedAnswer = try await signalManager.encrypt(
            plaintext: answerPayloadData, for: callerId, deviceId: 1)

        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        signal.encryptedSdpAnswer = encryptedAnswer
        outboundContinuation?.yield(signal)

        // 7. Send accepted control
        var controlSignal = Sanchr_Calling_CallSignal()
        controlSignal.callID = callId
        var acceptedControl = Sanchr_Calling_CallControl()
        acceptedControl.action = "accepted"
        controlSignal.control = acceptedControl
        outboundContinuation?.yield(controlSignal)

        let startTime = Date()
        self.callStartTime = startTime
        callState = .active(callId: callId, startTime: startTime)
        startDurationTimer(from: startTime)

        pendingSdpOffer = nil
    }

    /// Declines an incoming call.
    func declineCall() {
        guard let callId = callState.callId else { return }
        SanchrLogger.calls.info("Declining call \(callId)")

        // Send decline via signaling
        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        var declinedControl = Sanchr_Calling_CallControl()
        declinedControl.action = "declined"
        signal.control = declinedControl
        outboundContinuation?.yield(signal)

        endCallInternal(callId: callId, reason: .declined)
    }

    /// Ends the current active or outgoing call.
    func endCall() {
        guard let callId = callState.callId else { return }
        SanchrLogger.calls.info("Ending call \(callId)")

        // Send ended control via signaling
        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        var endedControl = Sanchr_Calling_CallControl()
        endedControl.action = "ended"
        signal.control = endedControl
        outboundContinuation?.yield(signal)

        // Also notify the server via the unary endCall RPC
        Task {
            var request = Sanchr_Calling_EndCallRequest()
            request.callID = callId
            _ = try? await callService.endCall(request)
        }

        endCallInternal(callId: callId, reason: .normal)
    }

    // MARK: - In-Call Controls

    func toggleMute() {
        isMuted = webRTCClient.toggleMute()
        // Sync with CallKit
        if let uuid = callUUID {
            let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
            let transaction = CXTransaction(action: action)
            callController.request(transaction) { error in
                if let error {
                    SanchrLogger.calls.error(
                        "Failed to sync mute with CallKit: \(error.localizedDescription)")
                }
            }
        }
    }

    func toggleSpeaker() {
        isSpeakerOn = webRTCClient.toggleSpeaker()
    }

    func toggleVideo() {
        isVideoEnabled = webRTCClient.toggleVideo()
    }

    func switchCamera() {
        _ = webRTCClient.toggleCamera()
    }

    func setVideoFilter(_ filter: VideoFilter) {
        currentVideoFilter = filter
        webRTCClient.setVideoFilter(filter)
    }

    // MARK: - Video Rendering Passthrough

    func attachLocalRenderer(_ renderer: RTCVideoRenderer) {
        webRTCClient.attachLocalRenderer(renderer)
    }

    func detachLocalRenderer(_ renderer: RTCVideoRenderer) {
        webRTCClient.detachLocalRenderer(renderer)
    }

    func attachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        webRTCClient.attachRemoteRenderer(renderer)
    }

    func detachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        webRTCClient.detachRemoteRenderer(renderer)
    }

    // MARK: - Signaling Stream

    /// Opens the bidirectional gRPC stream for exchanging SDP answers, ICE candidates, and control messages.
    private func openSignalingStream(callId: String) {
        let (outboundStream, continuation) = AsyncStream<Sanchr_Calling_CallSignal>.makeStream()
        // Continuation set synchronously before the reading Task spawns so that yields
        // issued immediately after this call returns are guaranteed to reach the stream.
        self.outboundContinuation = continuation

        signalingTask = Task { [weak self] in
            guard let self else { return }
            // Check cancellation before opening the gRPC stream — endCall() may have
            // already cancelled this task between openSignalingStream() returning and
            // this Task body executing on the cooperative thread pool.
            guard !Task.isCancelled else {
                SanchrLogger.calls.debug("Signaling task cancelled before stream open for call \(callId)")
                return
            }
            let inboundStream = self.callService.callStream(outboundStream)
            // Second check: endCall() may cancel during the synchronous stream setup above.
            guard !Task.isCancelled else {
                SanchrLogger.calls.debug("Signaling task cancelled after stream setup for call \(callId)")
                return
            }
            await self.handleSignalingStream(inboundStream, callId: callId)
            if !Task.isCancelled, self.callState.callId == callId {
                await MainActor.run {
                    self.endCallInternal(callId: callId, reason: .networkError)
                }
            }
        }
    }

    /// Processes incoming signaling messages from the bidirectional stream.
    private func handleSignalingStream(
        _ stream: GRPCAsyncResponseStream<Sanchr_Calling_CallSignal>, callId: String
    ) async {
        do {
            for try await signal in stream {
                guard !Task.isCancelled else { break }

                switch signal.signal {
                case .encryptedSdpAnswer(let ciphertext):
                    SanchrLogger.calls.info("Received encrypted SDP answer for call \(callId)")
                    guard let senderId = self.peerId else { continue }
                    do {
                        // FIXME: senderDevice hard-coded to 1 — multi-device accounts will not receive calls on other devices.
                        let plaintext = try await self.signalManager.decrypt(
                            ciphertext: ciphertext, from: senderId, senderDevice: 1)
                        let sealedPayload = try JSONDecoder().decode(SealedCallPayload.self, from: plaintext)
                        let age = abs(Date().timeIntervalSince1970 - sealedPayload.timestamp)
                        guard age <= 30 else {
                            SanchrLogger.calls.error("Rejecting stale SDP payload (age=\(Int(age))s)")
                            continue
                        }
                        // Verify DTLS fingerprint in SDP matches what was committed in the sealed payload.
                        // Missing fingerprint is treated as a rejection — a stripped fingerprint would
                        // bypass MITM protection entirely.
                        let remoteDesc = RTCSessionDescription(type: .answer, sdp: sealedPayload.sdp)
                        guard let sdpFingerprint = WebRTCClient.extractDtlsFingerprint(from: remoteDesc),
                              sdpFingerprint == sealedPayload.dtlsFingerprint else {
                            SanchrLogger.calls.error("DTLS fingerprint missing or mismatched — rejecting answer to prevent MITM")
                            continue
                        }
                        try await self.webRTCClient.setRemoteDescription(remoteDesc)
                        SanchrLogger.calls.info("E2EE answer: DTLS fingerprint verified = \(sealedPayload.dtlsFingerprint)")
                    } catch {
                        SanchrLogger.calls.error("Failed to decrypt SDP answer: \(error.localizedDescription)")
                    }

                case .iceCandidate(let candidateData):
                    guard let candidateDict = try? JSONSerialization.jsonObject(with: candidateData)
                            as? [String: Any],
                        let sdp = candidateDict["candidate"] as? String,
                        let sdpMLineIndex = candidateDict["sdpMLineIndex"] as? Int32
                    else {
                        continue
                    }
                    let sdpMid = candidateDict["sdpMid"] as? String
                    let candidate = RTCIceCandidate(
                        sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                    do {
                        try await webRTCClient.addIceCandidate(candidate)
                    } catch {
                        SanchrLogger.calls.error(
                            "Failed to add remote ICE candidate: \(error.localizedDescription)")
                    }

                case .control(let control):
                    await handleControlMessage(control, callId: callId)

                case nil:
                    SanchrLogger.calls.warning("Received signal with no active field")
                }
            }
        } catch {
            SanchrLogger.calls.error("Signaling stream error for call \(callId): \(error.localizedDescription)")
        }
    }

    /// Handles control messages: accepted, declined, busy, ended, ringing, missed.
    @MainActor
    private func handleControlMessage(_ control: Sanchr_Calling_CallControl, callId: String) {
        // Guard: ignore lifecycle/control events that belong to a different call.
        // Stale "ended" events from previous failed calls are queued in Redis and
        // replayed on stream reconnect — without this check they kill the new call.
        let currentCallId: String?
        switch callState {
        case .outgoing(let id, _), .ringing(let id), .incoming(let id, _, _),
             .active(let id, _), .reconnecting(let id), .ended(let id, _):
            currentCallId = id
        case .idle:
            currentCallId = nil
        }
        if let currentCallId, currentCallId != callId {
            SanchrLogger.calls.info(
                "Ignoring '\(control.action)' for stale call \(callId) (current: \(currentCallId))")
            return
        }

        SanchrLogger.calls.info("Control message: \(control.action) for call \(callId)")

        switch control.action {
        case "ringing":
            callState = .ringing(callId: callId)
            if let uuid = callUUID {
                provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            }

        case "accepted":
            let startTime = Date()
            self.callStartTime = startTime
            callState = .active(callId: callId, startTime: startTime)
            startDurationTimer(from: startTime)
            if let uuid = callUUID {
                provider.reportOutgoingCall(with: uuid, connectedAt: startTime)
            }

        case "declined":
            endCallInternal(callId: callId, reason: .declined)

        case "busy":
            endCallInternal(callId: callId, reason: .busy)

        case "ended":
            endCallInternal(callId: callId, reason: .normal)

        case "missed":
            endCallInternal(callId: callId, reason: .timeout)

        default:
            SanchrLogger.calls.warning("Unknown control action: \(control.action)")
        }
    }

    // MARK: - Duration Timer

    private func startDurationTimer(from startTime: Date) {
        durationTimer?.invalidate()
        callDuration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.callDuration = Date().timeIntervalSince(startTime)
        }
    }

    // MARK: - Internal Cleanup

    private func endCallInternal(callId: String, reason: CallState.EndReason) {
        // Guard: skip if this call has already been cleaned up
        switch callState {
        case .idle, .ended: return
        default: break
        }
        SanchrLogger.calls.info("Call ended: \(callId) reason=\(String(describing: reason))")

        durationTimer?.invalidate()
        durationTimer = nil
        callDuration = 0
        signalingTask?.cancel()
        signalingTask = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        pendingSdpOffer = nil

        callState = .ended(callId: callId, reason: reason)

        if let uuid = callUUID {
            let cxReason: CXCallEndedReason
            switch reason {
            case .normal: cxReason = .remoteEnded
            case .busy: cxReason = .unanswered
            case .declined: cxReason = .declinedElsewhere
            case .failed: cxReason = .failed
            case .timeout: cxReason = .unanswered
            case .networkError: cxReason = .failed
            }
            provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
            callUUID = nil
        }

        // Padding: keep peer connection alive until next time bucket, then tear down
        // For calls that never became active (e.g., busy/declined), use now as start
        // so that teardown is still padded to the first bucket (60 s), hiding whether
        // the call was answered from traffic analysis.
        let start = callStartTime ?? Date()
        let paddingTarget = CallDurationPaddingManager.paddingEnd(callStart: start, callEnd: Date())
        callStartTime = nil

        paddingManager.padThenComplete(target: paddingTarget) { [weak self] in
            guard let self else { return }
            self.webRTCClient.stopLocalMedia()
            self.webRTCClient.close()

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if case .ended = self.callState {
                    self.callState = .idle
                    self.isMuted = false
                    self.isSpeakerOn = false
                    self.isVideoEnabled = false
                    self.callType = "voice"
                    self.peerId = nil
                    self.peerName = nil
                    self.currentVideoFilter = .none
                }
            }
        }
    }

    func handleIncomingCallOffer(_ offer: Sanchr_Messaging_CallOfferEvent) {
        // If a VoIP push already set us to incoming for this exact call but the SDP
        // was absent from the push (payload too large), grab it from the stream replay.
        if case .incoming(let existingCallId, _, _) = callState,
           existingCallId == offer.callID,
           pendingSdpOffer == nil
        {
            SanchrLogger.calls.info(
                "Stream: received SDP for pending VoIP call \(offer.callID) — decrypting")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard !offer.encryptedSdpPayload.isEmpty else {
                        SanchrLogger.calls.error("Stream: SDP payload empty for pending call \(offer.callID)")
                        return
                    }
                    // FIXME: senderDevice hard-coded to 1
                    let plaintext = try await self.signalManager.decrypt(
                        ciphertext: offer.encryptedSdpPayload,
                        from: offer.callerID,
                        senderDevice: 1
                    )
                    let sealedPayload = try JSONDecoder().decode(SealedCallPayload.self, from: plaintext)
                    let offerDesc = RTCSessionDescription(type: .offer, sdp: sealedPayload.sdp)
                    guard let sdpFingerprint = WebRTCClient.extractDtlsFingerprint(from: offerDesc),
                          sdpFingerprint == sealedPayload.dtlsFingerprint
                    else {
                        SanchrLogger.calls.error("Stream: DTLS fingerprint mismatch for pending call \(offer.callID)")
                        return
                    }
                    self.pendingSdpOffer = Data(sealedPayload.sdp.utf8)
                    SanchrLogger.calls.info("Stream: SDP stored for pending VoIP call \(offer.callID)")
                } catch {
                    SanchrLogger.calls.error(
                        "Stream: SDP decryption failed for pending call \(offer.callID): \(error.localizedDescription)")
                }
            }
            return
        }

        guard case .idle = callState else {
            SanchrLogger.calls.warning("Ignoring incoming call offer while another call is active")
            return
        }

        Task {
            do {
                guard !offer.encryptedSdpPayload.isEmpty else {
                    SanchrLogger.calls.error("Rejecting unencrypted call offer from \(offer.callerID) — E2EE required")
                    return
                }
                // FIXME: senderDevice hard-coded to 1 — multi-device accounts will not receive calls on other devices.
                let plaintext = try await signalManager.decrypt(
                    ciphertext: offer.encryptedSdpPayload,
                    from: offer.callerID,
                    senderDevice: 1
                )
                let sealedPayload = try JSONDecoder().decode(SealedCallPayload.self, from: plaintext)
                let age = abs(Date().timeIntervalSince1970 - sealedPayload.timestamp)
                guard age <= 30 else {
                    SanchrLogger.calls.error("Rejecting stale incoming call offer (age=\(Int(age))s)")
                    return
                }
                let offerDesc = RTCSessionDescription(type: .offer, sdp: sealedPayload.sdp)
                guard let sdpFingerprint = WebRTCClient.extractDtlsFingerprint(from: offerDesc),
                      sdpFingerprint == sealedPayload.dtlsFingerprint else {
                    SanchrLogger.calls.error("DTLS fingerprint missing or mismatched — rejecting incoming offer to prevent MITM")
                    return
                }
                SanchrLogger.calls.info(
                    "E2EE offer verified from \(offer.callerID); fingerprint = \(sealedPayload.dtlsFingerprint)")

                await MainActor.run {
                    self.handleIncomingCall(
                        callId: offer.callID,
                        callerId: offer.callerID,
                        callerName: offer.callerID,
                        sdpOffer: Data(sealedPayload.sdp.utf8),
                        isVideo: offer.callType == "video"
                    )
                }
            } catch {
                SanchrLogger.calls.error(
                    "Failed to decrypt incoming call offer: \(error.localizedDescription)")
                // Do NOT open a signaling stream or send "declined" here.
                // We never reported this call to CallKit, so there is nothing to decline.
                // Opening an orphaned stream and sending "declined" would incorrectly tell
                // the caller the call was rejected, and leave stale signaling state.
                // The call will timeout on the caller's side naturally.
            }
        }
    }

    func handleCallLifecycleEvent(_ event: Sanchr_Messaging_CallLifecycleEvent) {
        if !event.peerID.isEmpty {
            peerId = event.peerID
            if peerName == nil || peerName?.isEmpty == true {
                peerName = event.peerID
            }
        }

        switch event.eventType {
        case "ringing":
            Task { @MainActor in
                handleControlMessage(controlMessage(action: "ringing"), callId: event.callID)
            }
        case "accepted":
            Task { @MainActor in
                handleControlMessage(controlMessage(action: "accepted"), callId: event.callID)
            }
        case "declined":
            Task { @MainActor in
                handleControlMessage(controlMessage(action: "declined"), callId: event.callID)
            }
        case "busy":
            Task { @MainActor in
                handleControlMessage(controlMessage(action: "busy"), callId: event.callID)
            }
        case "ended":
            Task { @MainActor in
                handleControlMessage(controlMessage(action: "ended"), callId: event.callID)
            }
        case "missed":
            Task { @MainActor in
                handleControlMessage(controlMessage(action: "missed"), callId: event.callID)
            }
        default:
            SanchrLogger.calls.info(
                "Ignoring unsupported call lifecycle event: \(event.eventType)")
        }
    }

    func resetState() {
        durationTimer?.invalidate()
        durationTimer = nil
        signalingTask?.cancel()
        signalingTask = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        pendingSdpOffer = nil
        callStartTime = nil
        callUUID = nil
        paddingManager.cancel()
        webRTCClient.stopLocalMedia()
        webRTCClient.close()
        callState = .idle
        isMuted = false
        isSpeakerOn = false
        isVideoEnabled = false
        callDuration = 0
        callType = "voice"
        peerId = nil
        peerName = nil
        currentVideoFilter = .none
    }

    private func controlMessage(action: String) -> Sanchr_Calling_CallControl {
        var control = Sanchr_Calling_CallControl()
        control.action = action
        return control
    }

    // MARK: - Helpers

    private func buildIceServers(from credentials: Sanchr_Calling_TurnCredentials) -> [RTCIceServer] {
        var servers: [RTCIceServer] = []

        // Add TURN servers with credentials
        if !credentials.urls.isEmpty {
            let turnServer = RTCIceServer(
                urlStrings: credentials.urls,
                username: credentials.username,
                credential: credentials.credential
            )
            servers.append(turnServer)
        }

        // Always include a public STUN server as fallback
        servers.append(RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]))

        return servers
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        SanchrLogger.calls.info("CallKit provider reset")
        if let callId = callState.callId {
            endCallInternal(callId: callId, reason: .failed)
        } else {
            webRTCClient.close()
            callState = .idle
        }
        callUUID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        SanchrLogger.calls.info("CallKit: perform CXStartCallAction")

        // Audio session will be activated by didActivate callback
        let update = CXCallUpdate()
        update.remoteHandle = action.handle
        update.hasVideo = action.isVideo
        update.localizedCallerName = action.contactIdentifier
        provider.reportCall(with: action.callUUID, updated: update)

        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        SanchrLogger.calls.info("CallKit: perform CXAnswerCallAction")

        let mgr = self
        let callAction = SendableAnswerAction(action: action)
        Task { @MainActor [callAction] in
            do {
                try await mgr.answerCall()
                callAction.action.fulfill()
            } catch {
                SanchrLogger.calls.error("Failed to answer call: \(error.localizedDescription)")
                callAction.action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        SanchrLogger.calls.info("CallKit: perform CXEndCallAction")

        if case .incoming = callState {
            declineCall()
        } else {
            endCall()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        SanchrLogger.calls.info("CallKit: perform CXSetMutedCallAction muted=\(action.isMuted)")
        if action.isMuted != isMuted {
            isMuted = webRTCClient.toggleMute()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        SanchrLogger.calls.info("CallKit: perform CXSetHeldCallAction held=\(action.isOnHold)")
        // Mute audio when on hold
        if action.isOnHold && !isMuted {
            isMuted = webRTCClient.toggleMute()
        } else if !action.isOnHold && isMuted {
            isMuted = webRTCClient.toggleMute()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        SanchrLogger.calls.info("Audio session activated by CallKit")
        // WebRTC audio is already configured; this callback confirms the system handoff.
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        SanchrLogger.calls.info("Audio session deactivated by CallKit")
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}

// MARK: - WebRTCClientDelegate

extension CallManager: WebRTCClientDelegate {

    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    {
        SanchrLogger.calls.info("WebRTC ICE state: \(state.rawValue)")

        Task { @MainActor in
            guard let callId = self.callState.callId else { return }

            switch state {
            case .connected, .completed:
                if case .active = self.callState {
                    // Already active, no state change needed
                } else {
                    let startTime = Date()
                    self.callState = .active(callId: callId, startTime: startTime)
                    self.startDurationTimer(from: startTime)
                    if let uuid = self.callUUID {
                        self.provider.reportOutgoingCall(with: uuid, connectedAt: startTime)
                    }
                }

            case .disconnected:
                self.callState = .reconnecting(callId: callId)

            case .failed:
                self.endCallInternal(callId: callId, reason: .failed)

            case .closed:
                break  // Handled by endCallInternal

            default:
                break
            }
        }
    }

    func webRTCClient(_ client: WebRTCClient, didReceiveLocalCandidate candidate: RTCIceCandidate) {
        guard let callId = callState.callId else { return }

        // Serialize candidate as JSON and send via signaling stream
        let candidateDict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? "",
        ]

        guard let candidateData = try? JSONSerialization.data(withJSONObject: candidateDict) else {
            SanchrLogger.calls.error("Failed to serialize ICE candidate")
            return
        }

        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        signal.iceCandidate = candidateData
        outboundContinuation?.yield(signal)
    }

    func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        SanchrLogger.calls.info("Remote video track received")
        // The view layer will attach renderers via attachRemoteRenderer
    }

    func webRTCClient(_ client: WebRTCClient, didChangeSignalingState state: RTCSignalingState) {
        SanchrLogger.calls.info("WebRTC signaling state: \(state.rawValue)")
    }
}
