import AVFoundation
@preconcurrency import CallKit
import Foundation
import GRPC
import UIKit
import WebRTC
import SanchrShared

protocol CallEventRouting: AnyObject, Sendable {
    func handleIncomingCallOffer(_ offer: Sanchr_Messaging_CallOfferEvent) async -> CallOfferHandlingOutcome
    func handleCallLifecycleEvent(_ event: Sanchr_Messaging_CallLifecycleEvent) async -> CallLifecycleHandlingOutcome
    func resetState()
}

enum CallOfferHandlingOutcome: Equatable, Sendable {
    case accepted
    case duplicate
    case terminalRejected
    case transientFailure
}

enum CallLifecycleHandlingOutcome: Equatable, Sendable {
    case applied
    case duplicate
    case ignored
}

private struct SendableAnswerAction: @unchecked Sendable {
    let action: CXAnswerCallAction
}

private struct SendableProvider: @unchecked Sendable {
    let provider: CXProvider
}

struct CallPeerProfile: Equatable, Sendable {
    let displayName: String?
    let avatarURL: URL?

    init(displayName: String?, avatarURL: URL? = nil) {
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
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
        case cancelled
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
    var peerIsMuted: Bool = false
    var peerBatteryIsLow: Bool = false
    var peerVideoEnabled: Bool = false
    var hasRemoteVideoTrack: Bool = false
    var incomingVideoUpgradeRequest: Bool = false
    var outgoingVideoUpgradePending: Bool = false
    var callDuration: TimeInterval = 0
    var callType: String = "voice"
    var peerId: String?
    var peerName: String?
    var peerAvatarURL: URL?
    var currentVideoFilter: VideoFilter = .none

    // MARK: - Dependencies

    private let webRTCClient: WebRTCClient
    private let callService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol
    private let provider: CXProvider
    private let callController: CXCallController
    private let signalManager: SignalProtocolManagerProtocol
    private let tokenRefresher: @Sendable () async throws -> Void
    private let peerProfileResolver: @Sendable (String) async -> CallPeerProfile?
    /// Returns the local Signal device id so outbound `CallSignal`s and
    /// `CallJoin.answererDevice` are stamped with the sender's actual device.
    /// Defaults to `{ 1 }` so existing tests need no changes.
    private let localDeviceIdProvider: @Sendable () -> Int32

    // MARK: - Internal State

    private var callUUID: UUID?
    private var pendingSdpOffer: Data?
    /// Signal device id of the current peer for decrypt/encrypt addressing.
    /// Set during incoming-offer decrypt from `CallOfferEvent.callerDevice`;
    /// read during outgoing-answer encrypt and during in-call signal decrypt.
    /// Zero means "not yet known" — callers must substitute a sensible default
    /// (today: device 1) when building a `ProtocolAddress`.
    private(set) var remoteCallerDevice: Int32 = 0
    private var paddingManager = CallDurationPaddingManager()
    private var callStartTime: Date?
    private var durationTask: Task<Void, Never>?
    private var signalingTask: Task<Void, Never>?
    private var signalingReadyCallId: String?
    private var pendingLocalIceCandidates: [Data] = []
    private var shouldIgnoreOutgoingCallKitEnd = false
    private var answeringCallId: String?
    private var localBatteryIsLow: Bool = false
    private var batteryMonitoringWasEnabled: Bool = false
    private var isBatteryMonitoringActive: Bool = false
    private let lowBatteryThreshold: Float = 0.20

    /// Continuation for sending signals through the bidirectional stream.
    private var outboundContinuation: AsyncStream<Sanchr_Calling_CallSignal>.Continuation?

    // MARK: - Init

    init(
        webRTCClient: WebRTCClient,
        callService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol,
        signalManager: SignalProtocolManagerProtocol,
        tokenRefresher: @escaping @Sendable () async throws -> Void = {},
        peerProfileResolver: @escaping @Sendable (String) async -> CallPeerProfile? = { _ in nil },
        localDeviceIdProvider: @escaping @Sendable () -> Int32 = { 1 }
    ) {
        self.webRTCClient = webRTCClient
        self.callService = callService
        self.signalManager = signalManager
        self.tokenRefresher = tokenRefresher
        self.peerProfileResolver = peerProfileResolver
        self.localDeviceIdProvider = localDeviceIdProvider

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

        // 5. Encrypt offer for E2EE — fan out per recipient device.
        guard let fingerprint = WebRTCClient.extractDtlsFingerprint(from: offer) else {
            throw AppError.callConnectionFailed
        }
        let payload = SealedCallPayload(
            sdp: offer.sdp,
            dtlsFingerprint: fingerprint,
            timestamp: Date().timeIntervalSince1970
        )
        let payloadData = try JSONEncoder().encode(payload)

        // Fresh PreKeySignalMessage per device is handled inside encryptCallOffers
        // (it resets each per-device session before encrypt).
        let callOffer = try await Self.buildOutgoingCallOffer(
            plaintext: payloadData,
            recipientId: recipientId,
            callType: isVideo ? "video" : "voice",
            signalManager: signalManager
        )

        // NOTE: delivery_token (sealed-sender call routing) is not yet implemented on the server.
        // sanchr-call routes via recipient_id and ignores the token field. Do not acquire a token
        // here — the acquisition is a blocking gRPC round-trip that fails and kills the call setup.

        // 6. Send the encrypted offer to the server.
        let response = try await callService.initiateCall(callOffer)
        let callId = response.callID

        SanchrLogger.calls.info("Call initiated, callId=\(callId), status=\(response.status)")

        if response.status == "busy" {
            callState = .ended(callId: callId, reason: .busy)
            pendingLocalIceCandidates.removeAll()
            webRTCClient.close()
            return
        }

        callState = .outgoing(callId: callId, recipientId: recipientId)
        peerId = recipientId
        peerName = recipientName
        peerAvatarURL = nil
        peerIsMuted = false
        peerBatteryIsLow = false
        peerVideoEnabled = isVideo
        hasRemoteVideoTrack = false
        incomingVideoUpgradeRequest = false
        outgoingVideoUpgradePending = false
        startBatteryMonitoring()
        resolveAndApplyPeerProfile(userId: recipientId, callId: callId, fallback: recipientName)

        // 6. Report to CallKit
        let uuid = UUID()
        self.callUUID = uuid
        self.shouldIgnoreOutgoingCallKitEnd = true

        let handle = CXHandle(type: .generic, value: recipientId)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = isVideo
        startAction.contactIdentifier = recipientName
        let transaction = CXTransaction(action: startAction)
        try await callController.request(transaction)

        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())

        // 7. Open bidirectional signaling stream
        openSignalingStream(callId: callId, role: "caller")
    }

    // MARK: - Incoming Call

    private static let unknownCallerName = "Unknown Caller"

    private static func displayNameCandidate(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else {
            return nil
        }
        return trimmed
    }

    private func currentDisplayName(for userId: String, fallback: String?) -> String {
        if peerId == userId, let currentName = Self.displayNameCandidate(peerName) {
            return currentName
        }
        if let fallbackName = Self.displayNameCandidate(fallback) {
            return fallbackName
        }
        return Self.unknownCallerName
    }

    private func resolvedPeerProfile(for userId: String, fallback: String?) async -> CallPeerProfile {
        let resolvedProfile = await peerProfileResolver(userId)
        let displayName = Self.displayNameCandidate(resolvedProfile?.displayName)
            ?? currentDisplayName(for: userId, fallback: fallback)
        return CallPeerProfile(
            displayName: displayName,
            avatarURL: resolvedProfile?.avatarURL
        )
    }

    private func resolveAndApplyPeerProfile(userId: String, callId: String, fallback: String?) {
        let resolver = peerProfileResolver
        let fallbackName = currentDisplayName(for: userId, fallback: fallback)
        let fallbackAvatarURL = peerId == userId ? peerAvatarURL : nil
        Task { [weak self] in
            let resolvedProfile = await resolver(userId)
            let displayName = Self.displayNameCandidate(resolvedProfile?.displayName) ?? fallbackName
            let avatarURL: URL?
            if let resolvedProfile {
                avatarURL = resolvedProfile.avatarURL
            } else {
                avatarURL = fallbackAvatarURL
            }

            await MainActor.run { [weak self] in
                guard let self,
                      self.callState.callId == callId,
                      self.peerId == userId
                else {
                    return
                }

                self.peerName = displayName
                self.peerAvatarURL = avatarURL
                if case .incoming(let incomingCallId, let callerId, _) = self.callState,
                   incomingCallId == callId
                {
                    self.callState = .incoming(
                        callId: incomingCallId,
                        callerId: callerId,
                        callerName: displayName
                    )
                }
                self.updateCallKitDisplayName(displayName, userId: userId)
            }
        }
    }

    private func updateCallKitDisplayName(_ displayName: String, userId: String) {
        guard let callUUID else { return }

        let update = CXCallUpdate()
        update.localizedCallerName = displayName
        update.remoteHandle = CXHandle(type: .generic, value: userId)
        update.hasVideo = callType == "video"
        update.supportsGrouping = false
        update.supportsHolding = true
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportCall(with: callUUID, updated: update)
    }

    private static var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    static func shouldReportIncomingCallToCallKit(
        applicationState: UIApplication.State,
        isSimulator: Bool
    ) -> Bool {
        guard !isSimulator else { return false }
        return applicationState != .active
    }

    /// Called when a push notification or signaling message delivers an incoming call.
    @MainActor
    func handleIncomingCall(
        callId: String,
        callerId: String,
        callerName: String,
        callerAvatarURL: URL? = nil,
        sdpOffer: Data,
        isVideo: Bool
    ) {
        SanchrLogger.calls.info(
            "Incoming \(isVideo ? "video" : "voice") call from \(callerName) [\(callId)]")

        self.callType = isVideo ? "video" : "voice"
        self.isVideoEnabled = isVideo
        self.pendingSdpOffer = sdpOffer
        self.peerId = callerId
        self.peerName = Self.displayNameCandidate(callerName) ?? Self.unknownCallerName
        self.peerAvatarURL = callerAvatarURL
        self.peerIsMuted = false
        self.peerBatteryIsLow = false
        self.peerVideoEnabled = isVideo
        self.hasRemoteVideoTrack = false
        self.incomingVideoUpgradeRequest = false
        self.outgoingVideoUpgradePending = false

        callState = .incoming(
            callId: callId,
            callerId: callerId,
            callerName: self.peerName ?? Self.unknownCallerName
        )
        startBatteryMonitoring()

        let shouldReportToCallKit = Self.shouldReportIncomingCallToCallKit(
            applicationState: UIApplication.shared.applicationState,
            isSimulator: Self.isRunningOnSimulator
        )
        if shouldReportToCallKit {
            let uuid = UUID()
            self.callUUID = uuid

            let update = CXCallUpdate()
            update.localizedCallerName = self.peerName
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
        } else {
            self.callUUID = nil
            SanchrLogger.calls.info(
                "Presenting incoming call in-app without CallKit for \(Self.isRunningOnSimulator ? "simulator" : "foreground") call \(callId)"
            )
        }

        resolveAndApplyPeerProfile(userId: callerId, callId: callId, fallback: callerName)
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
    ///   - callerDevice: The Signal device id of the calling device (0 when absent; fallback to 1).
    ///   - callType: "voice" or "video".
    ///   - encryptedSdpPayload: Raw bytes of the Signal-encrypted SDP offer.
    func handleVoIPPushIncomingCall(
        callId: String,
        callerId: String,
        callerDevice: Int32,
        callType: String,
        encryptedSdpPayload: Data
    ) {
        guard case .idle = callState else {
            // PushKit REQUIRES reportNewIncomingCall to be called synchronously on EVERY
            // return path — including state mismatches.  Returning without calling it causes
            // iOS to kill the app immediately with no grace period.
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: callerId)
            update.localizedCallerName = currentDisplayName(for: callerId, fallback: nil)
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
                let capturedProvider = SendableProvider(provider: provider)
                capturedProvider.provider.reportNewIncomingCall(with: throwawayUUID, update: update) { _ in
                    capturedProvider.provider.reportCall(
                        with: throwawayUUID,
                        endedAt: Date(),
                        reason: .unanswered
                    )
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
        self.peerName = Self.unknownCallerName
        self.peerAvatarURL = nil
        self.peerIsMuted = false
        self.peerBatteryIsLow = false
        self.peerVideoEnabled = callType == "video"
        self.hasRemoteVideoTrack = false
        self.incomingVideoUpgradeRequest = false
        self.outgoingVideoUpgradePending = false

        let uuid = UUID()
        self.callUUID = uuid
        callState = .incoming(
            callId: callId,
            callerId: callerId,
            callerName: Self.unknownCallerName
        )
        startBatteryMonitoring()

        let update = CXCallUpdate()
        update.localizedCallerName = Self.unknownCallerName
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

        resolveAndApplyPeerProfile(userId: callerId, callId: callId, fallback: nil)

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
            // caller_device is populated by multi-device-aware servers; legacy
            // servers leave it at 0. Fall back to device 1 so pre-multi-device
            // deployments keep working exactly as before.
            let resolvedDevice = Self.resolveSenderDevice(callerDevice)
            do {
                let plaintext = try await self.signalManager.decrypt(
                    ciphertext: encryptedSdpPayload,
                    from: callerId,
                    senderDevice: resolvedDevice
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

                self.remoteCallerDevice = resolvedDevice
                self.pendingSdpOffer = Data(sealedPayload.sdp.utf8)
                SanchrLogger.calls.info(
                    "VoIP push: SDP decrypted and stored for call \(callId)")
            } catch {
                SanchrLogger.calls.error(
                    "VoIP push: SDP decryption failed for call \(callId): \(error) [\(type(of: error))]")
                // Self-heal: reset session so caller's next attempt starts fresh.
                try? self.signalManager.resetSession(with: callerId, deviceId: resolvedDevice)
                // Don't end the call — give the user a chance to answer.
                // answerCall() will fail gracefully if SDP is still nil.
            }
        }
    }

    /// Requests CallKit to answer the incoming call. UI should use this path so
    /// CallKit activates the call instead of leaving it in an unanswered state.
    func requestAnswerCall() async throws {
        guard case .incoming(let callId, _, _) = callState else {
            SanchrLogger.calls.error("requestAnswerCall: not in incoming state")
            return
        }
        guard let callUUID else {
            SanchrLogger.calls.warning(
                "requestAnswerCall: missing CallKit UUID for \(callId), answering directly")
            try await answerCall()
            return
        }

        SanchrLogger.calls.info("Requesting CallKit answer for call \(callId)")
        let action = CXAnswerCallAction(call: callUUID)
        let transaction = CXTransaction(action: action)
        do {
            try await callController.request(transaction)
        } catch {
            SanchrLogger.calls.error(
                "CallKit answer request failed for \(callId): \(error.localizedDescription)")
            throw error
        }
    }

    /// Answers an incoming call after CallKit has accepted the answer action.
    func answerCall() async throws {
        guard case .incoming(let callId, _, _) = callState else {
            SanchrLogger.calls.error("answerCall: not in incoming state")
            return
        }
        if answeringCallId == callId {
            SanchrLogger.calls.info("answerCall: already answering call \(callId)")
            return
        }
        answeringCallId = callId
        defer {
            if answeringCallId == callId {
                answeringCallId = nil
            }
        }

        try await tokenRefresher()

        // For VoIP push calls the SDP is delivered by realtime replay; wait for the active ringing window.
        var sdpData: Data? = pendingSdpOffer
        if sdpData == nil {
            SanchrLogger.calls.info("answerCall: waiting for VoIP push SDP decryption...")
            for _ in 0..<240 {
                try await Task.sleep(for: .milliseconds(500))
                if let offer = pendingSdpOffer {
                    sdpData = offer
                    break
                }
            }
        }
        guard let sdpData else {
            SanchrLogger.calls.error("answerCall: SDP offer unavailable after ringing wait")
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
        openSignalingStream(callId: callId, role: "callee")
        try await sendEncryptedSessionDescription(answer, type: "answer", callId: callId)

        // 7. Send accepted control
        var controlSignal = Sanchr_Calling_CallSignal()
        controlSignal.callID = callId
        controlSignal.peerDevice = localDeviceIdProvider()
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
        signal.peerDevice = localDeviceIdProvider()
        var declinedControl = Sanchr_Calling_CallControl()
        declinedControl.action = "declined"
        signal.control = declinedControl
        outboundContinuation?.yield(signal)

        Task {
            await endCallOnServer(callId: callId, reason: "declined")
        }

        endCallInternal(callId: callId, reason: .declined)
    }

    /// Ends the current active or outgoing call.
    func endCall() {
        guard let callId = callState.callId else { return }
        SanchrLogger.calls.info("Ending call \(callId)")

        let reason = endReasonForCurrentState()

        // Send terminal control via signaling
        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        signal.peerDevice = localDeviceIdProvider()
        var terminalControl = Sanchr_Calling_CallControl()
        terminalControl.action = reason.serverReason
        signal.control = terminalControl
        outboundContinuation?.yield(signal)

        // Also notify the server via the unary endCall RPC
        Task {
            await endCallOnServer(callId: callId, reason: reason.serverReason)
        }

        endCallInternal(callId: callId, reason: reason.localReason)
    }

    // MARK: - In-Call Controls

    func toggleMute() {
        let targetMuted = !isMuted
        applyLocalMute(targetMuted, notifyPeer: true)

        // Keep CallKit's system UI in sync. Local mute is already applied, so a
        // transaction failure should not roll it back.
        if let uuid = callUUID {
            let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
            let transaction = CXTransaction(action: action)
            callController.request(transaction) { error in
                if let error {
                    SanchrLogger.calls.warning(
                        "CallKit mute sync failed, local mute remains \(targetMuted): \(error.localizedDescription)")
                }
            }
        }
    }

    func toggleSpeaker() {
        isSpeakerOn = webRTCClient.setSpeakerEnabled(!isSpeakerOn)
    }

    func toggleVideo() {
        if callType == "video" {
            let previousVideoEnabled = isVideoEnabled
            isVideoEnabled = webRTCClient.toggleVideo()
            if previousVideoEnabled != isVideoEnabled {
                sendControlAction(isVideoEnabled ? "video_on" : "video_off")
            }
        } else {
            requestVideoUpgrade()
        }
    }

    func requestVideoUpgrade() {
        guard case .active(let callId, _) = callState else {
            SanchrLogger.calls.warning("Ignoring video request outside active call")
            return
        }
        guard callType != "video" else {
            isVideoEnabled = webRTCClient.setVideoEnabled(true)
            return
        }
        guard !outgoingVideoUpgradePending else {
            SanchrLogger.calls.info("Video upgrade request already pending for call \(callId)")
            return
        }

        outgoingVideoUpgradePending = true
        sendControlAction("video_request", callId: callId)
    }

    func acceptVideoUpgradeRequest() async {
        guard let callId = callState.callId else { return }
        incomingVideoUpgradeRequest = false
        callType = "video"
        isVideoEnabled = webRTCClient.setVideoEnabled(true)
        peerVideoEnabled = true
        sendControlAction("video_accept", callId: callId)
        sendControlAction("video_on", callId: callId)
    }

    func declineVideoUpgradeRequest() {
        guard incomingVideoUpgradeRequest, let callId = callState.callId else { return }
        incomingVideoUpgradeRequest = false
        sendControlAction("video_decline", callId: callId)
    }

    func switchCamera() {
        _ = webRTCClient.toggleCamera()
    }

    func setVideoFilter(_ filter: VideoFilter) {
        currentVideoFilter = filter
        webRTCClient.setVideoFilter(filter)
    }

    private func applyLocalMute(_ muted: Bool, notifyPeer: Bool) {
        let previousMuted = isMuted
        isMuted = webRTCClient.setMuted(muted)
        if notifyPeer, previousMuted != isMuted {
            sendControlAction(isMuted ? "muted" : "unmuted")
        }
    }

    private func startVideoUpgradeOffer(callId: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run {
                    self.callType = "video"
                    self.isVideoEnabled = self.webRTCClient.setVideoEnabled(true)
                }

                let offer = try await self.webRTCClient.createOffer()
                try await self.webRTCClient.setLocalDescription(offer)
                try await self.sendEncryptedSessionDescription(offer, type: "offer", callId: callId)
                SanchrLogger.calls.info("Video upgrade offer sent for call \(callId)")
            } catch {
                await MainActor.run {
                    self.outgoingVideoUpgradePending = false
                    self.callType = "voice"
                    self.isVideoEnabled = self.webRTCClient.setVideoEnabled(false)
                }
                self.sendControlAction("video_failed", callId: callId)
                SanchrLogger.calls.error(
                    "Failed to start video upgrade for call \(callId): \(error.localizedDescription)"
                )
            }
        }
    }

    private func handleVideoUpgradeOffer(_ payload: SealedCallPayload, callId: String) async throws {
        await MainActor.run {
            callType = "video"
            isVideoEnabled = webRTCClient.setVideoEnabled(true)
            peerVideoEnabled = true
        }

        let remoteDescription = RTCSessionDescription(type: .offer, sdp: payload.sdp)
        try await webRTCClient.setRemoteDescription(remoteDescription)

        let answer = try await webRTCClient.createAnswer()
        try await webRTCClient.setLocalDescription(answer)
        try await sendEncryptedSessionDescription(answer, type: "answer", callId: callId)
        SanchrLogger.calls.info("Video upgrade answer sent for call \(callId)")
    }

    private func sendEncryptedSessionDescription(
        _ description: RTCSessionDescription,
        type: String,
        callId: String
    ) async throws {
        guard let recipientId = peerId else {
            throw AppError.callConnectionFailed
        }
        guard let fingerprint = WebRTCClient.extractDtlsFingerprint(from: description) else {
            throw AppError.callConnectionFailed
        }

        // Delegate encrypt + payload construction to the pure static helper so
        // the device-selection logic is unit-testable without a WebRTC pipeline.
        let encryptedPayload = try await Self.buildEncryptedAnswerPayload(
            sdp: description.sdp,
            fingerprint: fingerprint,
            type: type,
            remoteCallerDevice: remoteCallerDevice,
            recipientId: recipientId,
            signalManager: signalManager
        )

        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        signal.encryptedSdpAnswer = encryptedPayload
        signal.peerDevice = localDeviceIdProvider()
        outboundContinuation?.yield(signal)
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
    private func openSignalingStream(callId: String, role: String) {
        if signalingReadyCallId == callId, outboundContinuation != nil {
            flushLocalIceCandidates(callId: callId)
            return
        }

        let (outboundStream, continuation) = AsyncStream<Sanchr_Calling_CallSignal>.makeStream()
        // Continuation set synchronously before the reading Task spawns so that yields
        // issued immediately after this call returns are guaranteed to reach the stream.
        self.outboundContinuation = continuation
        self.signalingReadyCallId = callId

        var joinSignal = Sanchr_Calling_CallSignal()
        joinSignal.callID = callId
        joinSignal.peerDevice = localDeviceIdProvider()
        var join = Sanchr_Calling_CallJoin()
        join.role = role
        // Only the callee populates answererDevice — the server reads it to
        // know which callee device to mirror onto the caller's stream as
        // CallSignal.peerDevice. If the caller also set this field, the
        // server would have to role-filter to avoid using the wrong value.
        if role == "callee" {
            join.answererDevice = localDeviceIdProvider()
        }
        joinSignal.join = join
        continuation.yield(joinSignal)
        flushLocalIceCandidates(callId: callId)
        sendLocalStatusControls(callId: callId)

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
                        // Decrypt using the callee's device id from CallSignal.peerDevice
                        // (server-mirrored from CallJoin.answererDevice). Falls back to
                        // device 1 via resolveSenderDevice for legacy callee paths.
                        let sealedPayload = try await Self.decryptIncomingAnswer(
                            ciphertext: ciphertext,
                            peerDevice: signal.peerDevice,
                            senderId: senderId,
                            signalManager: self.signalManager
                        )
                        let age = abs(Date().timeIntervalSince1970 - sealedPayload.timestamp)
                        guard age <= 30 else {
                            SanchrLogger.calls.error("Rejecting stale SDP payload (age=\(Int(age))s)")
                            continue
                        }
                        // Verify DTLS fingerprint in SDP matches what was committed in the sealed payload.
                        // Missing fingerprint is treated as a rejection — a stripped fingerprint would
                        // bypass MITM protection entirely.
                        let descriptionType = sealedPayload.type ?? "answer"
                        let rtcDescriptionType: RTCSdpType = descriptionType == "offer" ? .offer : .answer
                        let remoteDesc = RTCSessionDescription(type: rtcDescriptionType, sdp: sealedPayload.sdp)
                        guard let sdpFingerprint = WebRTCClient.extractDtlsFingerprint(from: remoteDesc),
                              sdpFingerprint == sealedPayload.dtlsFingerprint else {
                            SanchrLogger.calls.error("DTLS fingerprint missing or mismatched — rejecting answer to prevent MITM")
                            continue
                        }
                        if descriptionType == "offer" {
                            try await self.handleVideoUpgradeOffer(sealedPayload, callId: callId)
                            SanchrLogger.calls.info("E2EE video offer verified = \(sealedPayload.dtlsFingerprint)")
                        } else {
                            try await self.webRTCClient.setRemoteDescription(remoteDesc)
                            await MainActor.run {
                                self.outgoingVideoUpgradePending = false
                            }
                            SanchrLogger.calls.info("E2EE answer: DTLS fingerprint verified = \(sealedPayload.dtlsFingerprint)")
                        }
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

                case .join(_):
                    SanchrLogger.calls.debug("Ignoring server-side call join echo for \(callId)")

                case nil:
                    SanchrLogger.calls.warning("Received signal with no active field")
                }
            }
        } catch {
            SanchrLogger.calls.error("Signaling stream error for call \(callId): \(error.localizedDescription)")
        }
    }

    @MainActor
    func handleControlAction(_ action: String, callId: String) {
        handleControlMessage(controlMessage(action: action), callId: callId)
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

        if shouldIgnoreDuplicateControl(control.action, callId: callId) {
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
            shouldIgnoreOutgoingCallKitEnd = false
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

        case "cancelled":
            endCallInternal(callId: callId, reason: .cancelled)

        case "missed":
            endCallInternal(callId: callId, reason: .timeout)

        case "failed":
            endCallInternal(callId: callId, reason: .failed)

        case "muted":
            peerIsMuted = true

        case "unmuted":
            peerIsMuted = false

        case "battery_low":
            peerBatteryIsLow = true

        case "battery_ok":
            peerBatteryIsLow = false

        case "video_request":
            handleVideoUpgradeRequest(callId: callId)

        case "video_accept":
            guard outgoingVideoUpgradePending else {
                SanchrLogger.calls.info("Ignoring duplicate video_accept for call \(callId)")
                return
            }
            peerVideoEnabled = true
            startVideoUpgradeOffer(callId: callId)

        case "video_decline":
            outgoingVideoUpgradePending = false

        case "video_on":
            peerVideoEnabled = true

        case "video_off":
            peerVideoEnabled = false

        case "video_failed":
            outgoingVideoUpgradePending = false
            incomingVideoUpgradeRequest = false
            peerVideoEnabled = false
            hasRemoteVideoTrack = false
            if callType == "video" {
                callType = "voice"
                isVideoEnabled = webRTCClient.setVideoEnabled(false)
            }

        default:
            SanchrLogger.calls.warning("Unknown control action: \(control.action)")
        }
    }

    private func handleVideoUpgradeRequest(callId: String) {
        guard case .active(let activeCallId, _) = callState,
              activeCallId == callId
        else {
            SanchrLogger.calls.info("Ignoring video request outside active call \(callId)")
            return
        }

        if callType == "video" {
            sendControlAction("video_accept", callId: callId)
            return
        }

        incomingVideoUpgradeRequest = true
    }

    private func shouldIgnoreDuplicateControl(_ action: String, callId: String) -> Bool {
        switch (action, callState) {
        case ("accepted", .active(let activeCallId, _)),
             ("accepted", .reconnecting(let activeCallId)):
            guard activeCallId == callId else { return false }
            SanchrLogger.calls.info("Ignoring duplicate accepted control for call \(callId)")
            return true

        case ("ended", .ended(let endedCallId, _)),
             ("cancelled", .ended(let endedCallId, _)),
             ("declined", .ended(let endedCallId, _)),
             ("busy", .ended(let endedCallId, _)),
             ("missed", .ended(let endedCallId, _)),
             ("failed", .ended(let endedCallId, _)):
            guard endedCallId == callId else { return false }
            SanchrLogger.calls.info("Ignoring duplicate terminal control \(action) for call \(callId)")
            return true

        default:
            return false
        }
    }

    // MARK: - Duration Timer

    private func startDurationTimer(from startTime: Date) {
        durationTask?.cancel()
        callDuration = max(0, Date().timeIntervalSince(startTime))
        durationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.callDuration = max(0, Date().timeIntervalSince(startTime))

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
    }

    private func stopDurationTimer() {
        durationTask?.cancel()
        durationTask = nil
        callDuration = 0
    }

    // MARK: - Internal Cleanup

    private func endCallInternal(callId: String, reason: CallState.EndReason) {
        // Guard: skip if this call has already been cleaned up
        switch callState {
        case .idle, .ended: return
        default: break
        }
        SanchrLogger.calls.info("Call ended: \(callId) reason=\(String(describing: reason))")

        stopDurationTimer()
        signalingTask?.cancel()
        signalingTask = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        signalingReadyCallId = nil
        pendingLocalIceCandidates.removeAll()
        pendingSdpOffer = nil
        shouldIgnoreOutgoingCallKitEnd = false
        answeringCallId = nil
        incomingVideoUpgradeRequest = false
        outgoingVideoUpgradePending = false
        stopBatteryMonitoring()
        webRTCClient.stopLocalMedia()
        webRTCClient.close()

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
            case .cancelled: cxReason = .remoteEnded
            }
            provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
            callUUID = nil
        }

        callStartTime = nil

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            if case .ended = self.callState {
                self.callState = .idle
                self.isMuted = false
                self.isSpeakerOn = false
                self.isVideoEnabled = false
                self.peerIsMuted = false
                self.peerBatteryIsLow = false
                self.peerVideoEnabled = false
                self.hasRemoteVideoTrack = false
                self.incomingVideoUpgradeRequest = false
                self.outgoingVideoUpgradePending = false
                self.callType = "voice"
                self.peerId = nil
                self.peerName = nil
                self.peerAvatarURL = nil
                self.currentVideoFilter = .none
            }
        }
    }

    func handleIncomingCallOffer(_ offer: Sanchr_Messaging_CallOfferEvent) async -> CallOfferHandlingOutcome {
        // If a VoIP push already set us to incoming for this exact call but the SDP
        // was absent from the push (payload too large), grab it from the stream replay.
        if case .incoming(let existingCallId, _, _) = callState,
           existingCallId == offer.callID,
           pendingSdpOffer == nil
        {
            SanchrLogger.calls.info(
                "Stream: received SDP for pending VoIP call \(offer.callID) — decrypting")
            do {
                let sdp = try await decryptAndValidateOffer(offer, maxAgeSeconds: 120)
                pendingSdpOffer = Data(sdp.utf8)
                resolveAndApplyPeerProfile(
                    userId: offer.callerID,
                    callId: offer.callID,
                    fallback: nil
                )
                SanchrLogger.calls.info("Stream: SDP stored for pending VoIP call \(offer.callID)")
                return .accepted
            } catch {
                SanchrLogger.calls.error(
                    "Stream: SDP decryption failed for pending call \(offer.callID): \(error) [\(type(of: error))]")
                let resetDevice = Self.resolveSenderDevice(offer.callerDevice)
                try? self.signalManager.resetSession(with: offer.callerID, deviceId: resetDevice)
                return .transientFailure
            }
        }

        if callState.callId == offer.callID {
            SanchrLogger.calls.info("Duplicate call offer for current call \(offer.callID)")
            return .duplicate
        }

        guard case .idle = callState else {
            SanchrLogger.calls.warning("Rejecting incoming call offer as busy while another call is active")
            Task {
                await endCallOnServer(callId: offer.callID, reason: "busy")
            }
            return .terminalRejected
        }

        do {
            let sdp = try await decryptAndValidateOffer(offer, maxAgeSeconds: 30)
            let callerProfile = await resolvedPeerProfile(for: offer.callerID, fallback: nil)
            let callerName = callerProfile.displayName ?? Self.unknownCallerName
            SanchrLogger.calls.info("E2EE offer verified from \(offer.callerID)")
            await MainActor.run {
                self.handleIncomingCall(
                    callId: offer.callID,
                    callerId: offer.callerID,
                    callerName: callerName,
                    callerAvatarURL: callerProfile.avatarURL,
                    sdpOffer: Data(sdp.utf8),
                    isVideo: offer.callType == "video"
                )
            }
            return .accepted
        } catch {
            SanchrLogger.calls.error(
                "Failed to decrypt incoming call offer from \(offer.callerID.prefix(8))...: \(error) [\(type(of: error))]")
            let resetDevice = Self.resolveSenderDevice(offer.callerDevice)
            try? signalManager.resetSession(with: offer.callerID, deviceId: resetDevice)
            return .transientFailure
        }
    }

    func handleCallLifecycleEvent(_ event: Sanchr_Messaging_CallLifecycleEvent) async -> CallLifecycleHandlingOutcome {
        if let currentCallId = callState.callId, currentCallId != event.callID {
            SanchrLogger.calls.info(
                "Ignoring lifecycle \(event.eventType) for stale call \(event.callID) (current: \(currentCallId))")
            return .ignored
        }

        if !event.peerID.isEmpty {
            peerId = event.peerID
            if peerName == nil || peerName?.isEmpty == true || peerName == event.peerID {
                peerName = currentDisplayName(for: event.peerID, fallback: nil)
            }
            resolveAndApplyPeerProfile(
                userId: event.peerID,
                callId: event.callID,
                fallback: nil
            )
        }

        switch event.eventType {
        case "ringing":
            await MainActor.run {
                handleControlAction("ringing", callId: event.callID)
            }
            return .applied
        case "accepted":
            await MainActor.run {
                handleControlAction("accepted", callId: event.callID)
            }
            return .applied
        case "declined":
            await MainActor.run {
                handleControlAction("declined", callId: event.callID)
            }
            return .applied
        case "busy":
            await MainActor.run {
                handleControlAction("busy", callId: event.callID)
            }
            return .applied
        case "ended":
            await MainActor.run {
                handleControlAction("ended", callId: event.callID)
            }
            return .applied
        case "cancelled":
            await MainActor.run {
                handleControlAction("cancelled", callId: event.callID)
            }
            return .applied
        case "missed":
            await MainActor.run {
                handleControlAction("missed", callId: event.callID)
            }
            return .applied
        case "failed":
            await MainActor.run {
                handleControlAction("failed", callId: event.callID)
            }
            return .applied
        default:
            SanchrLogger.calls.info(
                "Ignoring unsupported call lifecycle event: \(event.eventType)")
            return .ignored
        }
    }

    func resetState() {
        stopDurationTimer()
        signalingTask?.cancel()
        signalingTask = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        signalingReadyCallId = nil
        pendingLocalIceCandidates.removeAll()
        pendingSdpOffer = nil
        shouldIgnoreOutgoingCallKitEnd = false
        answeringCallId = nil
        stopBatteryMonitoring()
        callStartTime = nil
        callUUID = nil
        paddingManager.cancel()
        webRTCClient.stopLocalMedia()
        webRTCClient.close()
        callState = .idle
        isMuted = false
        isSpeakerOn = false
        isVideoEnabled = false
        peerIsMuted = false
        peerBatteryIsLow = false
        peerVideoEnabled = false
        hasRemoteVideoTrack = false
        incomingVideoUpgradeRequest = false
        outgoingVideoUpgradePending = false
        callDuration = 0
        callType = "voice"
        peerId = nil
        peerName = nil
        peerAvatarURL = nil
        currentVideoFilter = .none
        // Reset the resolved sender device so the next call's return-path
        // encrypt does not inherit a stale device id from a prior session.
        // Sub-phase D's sendEncryptedSessionDescription reads this; without
        // the reset, a sequential call from a different device would encrypt
        // the answer for the wrong Signal session.
        remoteCallerDevice = 0
    }

    private func controlMessage(action: String) -> Sanchr_Calling_CallControl {
        var control = Sanchr_Calling_CallControl()
        control.action = action
        return control
    }

    private func sendControlAction(_ action: String, callId explicitCallId: String? = nil) {
        guard let callId = explicitCallId ?? callState.callId else { return }
        guard outboundContinuation != nil, signalingReadyCallId == callId else {
            SanchrLogger.calls.debug("Deferred call control \(action) until stream opens")
            return
        }

        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        signal.peerDevice = localDeviceIdProvider()
        signal.control = controlMessage(action: action)
        outboundContinuation?.yield(signal)
        SanchrLogger.calls.info("Sent call control: \(action) for call \(callId)")
    }

    private func sendLocalStatusControls(callId: String) {
        sendControlAction(isMuted ? "muted" : "unmuted", callId: callId)
        sendControlAction(localBatteryIsLow ? "battery_low" : "battery_ok", callId: callId)
        if callType == "video" {
            sendControlAction(isVideoEnabled ? "video_on" : "video_off", callId: callId)
        }
    }

    private func startBatteryMonitoring() {
        Task { @MainActor [weak self] in
            self?.startBatteryMonitoringOnMainActor()
        }
    }

    @MainActor
    private func startBatteryMonitoringOnMainActor() {
        if isBatteryMonitoringActive {
            updateLocalBatteryStatusOnMainActor(force: true)
            return
        }

        let device = UIDevice.current
        batteryMonitoringWasEnabled = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        isBatteryMonitoringActive = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBatteryStatusChanged(_:)),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: device
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBatteryStatusChanged(_:)),
            name: UIDevice.batteryStateDidChangeNotification,
            object: device
        )

        updateLocalBatteryStatusOnMainActor(force: true)
    }

    private func stopBatteryMonitoring() {
        Task { @MainActor [weak self] in
            self?.stopBatteryMonitoringOnMainActor()
        }
    }

    @MainActor
    private func stopBatteryMonitoringOnMainActor() {
        guard isBatteryMonitoringActive else { return }

        let device = UIDevice.current
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.batteryLevelDidChangeNotification,
            object: device
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.batteryStateDidChangeNotification,
            object: device
        )
        if !batteryMonitoringWasEnabled {
            device.isBatteryMonitoringEnabled = false
        }

        batteryMonitoringWasEnabled = false
        isBatteryMonitoringActive = false
        localBatteryIsLow = false
    }

    @objc private func handleBatteryStatusChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.updateLocalBatteryStatusOnMainActor(force: false)
        }
    }

    @MainActor
    private func updateLocalBatteryStatusOnMainActor(force: Bool) {
        let level = UIDevice.current.batteryLevel
        let isLow = level >= 0 && level <= lowBatteryThreshold
        let changed = isLow != localBatteryIsLow
        localBatteryIsLow = isLow

        if force || changed {
            sendControlAction(isLow ? "battery_low" : "battery_ok")
        }
    }

    private func endReasonForCurrentState() -> (serverReason: String, localReason: CallState.EndReason) {
        switch callState {
        case .active, .reconnecting:
            return ("ended", .normal)
        case .outgoing, .ringing, .incoming:
            return ("cancelled", .cancelled)
        case .ended(_, let reason):
            return ("ended", reason)
        case .idle:
            return ("ended", .normal)
        }
    }

    private func endCallOnServer(callId: String, reason: String) async {
        do {
            try await tokenRefresher()
            var request = Sanchr_Calling_EndCallRequest()
            request.callID = callId
            request.reason = reason
            _ = try await callService.endCall(request)
        } catch {
            SanchrLogger.calls.error(
                "endCall RPC failed for \(callId) reason=\(reason): \(error.localizedDescription)")
        }
    }

    private func flushLocalIceCandidates(callId: String) {
        guard outboundContinuation != nil, signalingReadyCallId == callId else { return }
        let candidates = pendingLocalIceCandidates
        pendingLocalIceCandidates.removeAll()
        for candidateData in candidates {
            var signal = Sanchr_Calling_CallSignal()
            signal.callID = callId
            signal.peerDevice = localDeviceIdProvider()
            signal.iceCandidate = candidateData
            outboundContinuation?.yield(signal)
        }
        if !candidates.isEmpty {
            SanchrLogger.calls.info("Flushed \(candidates.count) buffered local ICE candidates for \(callId)")
        }
    }

    private func sendOrBufferLocalIceCandidate(_ candidateData: Data) {
        guard let callId = callState.callId else {
            pendingLocalIceCandidates.append(candidateData)
            return
        }
        guard outboundContinuation != nil, signalingReadyCallId == callId else {
            pendingLocalIceCandidates.append(candidateData)
            return
        }

        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        signal.peerDevice = localDeviceIdProvider()
        signal.iceCandidate = candidateData
        outboundContinuation?.yield(signal)
    }

    /// Decrypts and validates an incoming call offer.
    /// - Returns: The plaintext SDP string on success.
    /// - Throws: `AppError.decryptionFailed` when the Signal decrypt fails,
    ///   the payload is stale, or the embedded DTLS fingerprint does not
    ///   match the SDP's. All failures log the reason and do not surface the
    ///   raw decrypt error to the caller.
    private func decryptAndValidateOffer(
        _ offer: Sanchr_Messaging_CallOfferEvent,
        maxAgeSeconds: TimeInterval
    ) async throws -> String {
        guard !offer.encryptedSdpPayload.isEmpty else {
            throw AppError.decryptionFailed(reason: "encrypted call offer payload is empty")
        }
        let senderDevice = Self.resolveSenderDevice(offer.callerDevice)
        let plaintext = try await signalManager.decrypt(
            ciphertext: offer.encryptedSdpPayload,
            from: offer.callerID,
            senderDevice: senderDevice
        )
        let sealedPayload = try JSONDecoder().decode(SealedCallPayload.self, from: plaintext)
        let age = abs(Date().timeIntervalSince1970 - sealedPayload.timestamp)
        guard age <= maxAgeSeconds else {
            throw AppError.decryptionFailed(reason: "stale call offer age=\(Int(age))s")
        }
        let offerDesc = RTCSessionDescription(type: .offer, sdp: sealedPayload.sdp)
        guard let sdpFingerprint = WebRTCClient.extractDtlsFingerprint(from: offerDesc),
              sdpFingerprint == sealedPayload.dtlsFingerprint
        else {
            throw AppError.decryptionFailed(reason: "DTLS fingerprint missing or mismatched")
        }
        // Persist the sender device so the answer we send back encrypts for
        // the exact session we just decrypted from, not device 1.
        self.remoteCallerDevice = senderDevice
        return sealedPayload.sdp
    }

    // MARK: - Helpers

    /// Resolves a peer's Signal device id, falling back to device 1 (the
    /// primary device) when the wire-level value is absent (zero). The
    /// fallback exists for backward compatibility with pre-multi-device
    /// servers — once the backend reliably populates `caller_device` /
    /// `peer_device` / `answerer_device`, the `else 1` branch can be removed
    /// in a single place. See Sub-phase C of the calls-hardening plan.
    static func resolveSenderDevice(_ raw: Int32) -> Int32 {
        raw > 0 ? raw : 1
    }

    private func buildIceServers(from credentials: Sanchr_Calling_TurnCredentials) -> [RTCIceServer] {
        Self.buildIceServersImpl(
            from: credentials,
            stunServers: AppConfiguration.current.stunServers
        )
    }

    /// Pure builder — testable without standing up a CallManager. Includes a
    /// final-fallback Google STUN entry only when the configured `stunServers`
    /// list is empty so that a misconfigured environment still degrades to a
    /// working call rather than a no-ICE failure.
    static func buildIceServersImpl(
        from credentials: Sanchr_Calling_TurnCredentials,
        stunServers: [String]
    ) -> [RTCIceServer] {
        var servers: [RTCIceServer] = []

        if !credentials.urls.isEmpty {
            servers.append(RTCIceServer(
                urlStrings: credentials.urls,
                username: credentials.username,
                credential: credentials.credential
            ))
        }

        if stunServers.isEmpty {
            servers.append(RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]))
        } else {
            servers.append(RTCIceServer(urlStrings: stunServers))
        }

        return servers
    }

    /// Pure builder for the outgoing `CallOffer` — extracted from `startCall`
    /// so multi-device fan-out can be tested without standing up WebRTC.
    /// Calls `signalManager.encryptCallOffers` to encrypt the SDP payload once
    /// per recipient device, then assembles the `CallOffer` with the full
    /// `device_offers` list and a legacy `encrypted_sdp_payload` mirroring the
    /// device-1 entry (or the lowest-device-id entry when device 1 is absent).
    /// Throws `AppError.callConnectionFailed` when the recipient has no
    /// registered devices to route the offer to.
    static func buildOutgoingCallOffer(
        plaintext: Data,
        recipientId: String,
        callType: String,
        signalManager: SignalProtocolManagerProtocol
    ) async throws -> Sanchr_Calling_CallOffer {
        let deviceOffers = try await signalManager.encryptCallOffers(
            plaintext: plaintext,
            recipientId: recipientId
        )
        guard let legacyEntry = deviceOffers.first(where: { $0.deviceID == 1 })
            ?? deviceOffers.min(by: { $0.deviceID < $1.deviceID })
        else {
            SanchrLogger.calls.fault(
                "buildOutgoingCallOffer: no recipient devices for \(recipientId.prefix(8))... — cannot route offer")
            throw AppError.callConnectionFailed
        }

        var offer = Sanchr_Calling_CallOffer()
        offer.recipientID = recipientId
        offer.callType = callType
        offer.deviceOffers = deviceOffers
        offer.encryptedSdpPayload = legacyEntry.encryptedSdpPayload
        return offer
    }

    /// Pure helper — testable without standing up a full WebRTC/CallKit pipeline.
    /// Encodes the SDP payload as a `SealedCallPayload`, then encrypts it for
    /// `recipientId` on `remoteCallerDevice` (falls back to device 1 via
    /// `resolveSenderDevice` when the caller device is not yet known).
    ///
    /// Extracted from `sendEncryptedSessionDescription` so the device-selection
    /// logic can be exercised directly in unit tests (see Sub-phase E of the
    /// calls-hardening plan).
    static func buildEncryptedAnswerPayload(
        sdp: String,
        fingerprint: String,
        type: String,
        remoteCallerDevice: Int32,
        recipientId: String,
        signalManager: SignalProtocolManagerProtocol
    ) async throws -> Data {
        let payload = SealedCallPayload(
            sdp: sdp,
            dtlsFingerprint: fingerprint,
            timestamp: Date().timeIntervalSince1970,
            type: type
        )
        let payloadData = try JSONEncoder().encode(payload)
        // Encrypt for the exact caller device recovered during offer decrypt.
        // Falls back to device 1 when remoteCallerDevice is zero (legacy path).
        let targetDevice = Self.resolveSenderDevice(remoteCallerDevice)
        return try await signalManager.encrypt(
            plaintext: payloadData,
            for: recipientId,
            deviceId: targetDevice
        )
    }

    /// Pure helper — testable without standing up a signaling loop.
    /// Decrypts an incoming encrypted SDP answer using the callee's device id
    /// from `CallSignal.peerDevice` (falls back to device 1 via
    /// `resolveSenderDevice` when the field is absent/zero).
    ///
    /// Extracted from `handleSignalingStream`'s `encryptedSdpAnswer` branch so
    /// the peerDevice selection logic can be verified directly in unit tests
    /// (see Sub-phase E of the calls-hardening plan).
    static func decryptIncomingAnswer(
        ciphertext: Data,
        peerDevice: Int32,
        senderId: String,
        signalManager: SignalProtocolManagerProtocol
    ) async throws -> SealedCallPayload {
        let resolvedDevice = Self.resolveSenderDevice(peerDevice)
        let plaintext = try await signalManager.decrypt(
            ciphertext: ciphertext,
            from: senderId,
            senderDevice: resolvedDevice
        )
        return try JSONDecoder().decode(SealedCallPayload.self, from: plaintext)
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        SanchrLogger.calls.info("CallKit provider reset")
        if let callId = callState.callId {
            Task {
                await endCallOnServer(callId: callId, reason: "failed")
            }
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

        if shouldIgnoreOutgoingCallKitEnd(action: action) {
            SanchrLogger.calls.warning("CallKit: ignored outgoing CXEndCallAction before call activation")
            action.fulfill()
            return
        }

        switch callState {
        case .idle, .ended:
            SanchrLogger.calls.info("CallKit: ignored CXEndCallAction because call is already closed")
        case .incoming:
            SanchrLogger.calls.warning("CallKit requested end for incoming call; treating it as decline")
            declineCall()
        default:
            endCall()
        }
        action.fulfill()
    }

    private func shouldIgnoreOutgoingCallKitEnd(action: CXEndCallAction) -> Bool {
        guard let callUUID, callUUID == action.callUUID, shouldIgnoreOutgoingCallKitEnd else {
            return false
        }

        switch callState {
        case .outgoing, .ringing:
            return true
        default:
            return false
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        SanchrLogger.calls.info("CallKit: perform CXSetMutedCallAction muted=\(action.isMuted)")
        applyLocalMute(action.isMuted, notifyPeer: true)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        SanchrLogger.calls.info("CallKit: perform CXSetHeldCallAction held=\(action.isOnHold)")
        // Mute audio when on hold
        if action.isOnHold && !isMuted {
            applyLocalMute(true, notifyPeer: true)
        } else if !action.isOnHold && isMuted {
            applyLocalMute(false, notifyPeer: true)
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
                    self.shouldIgnoreOutgoingCallKitEnd = false
                    // Already active, no state change needed
                } else {
                    let startTime = Date()
                    self.shouldIgnoreOutgoingCallKitEnd = false
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

        sendOrBufferLocalIceCandidate(candidateData)
    }

    func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        SanchrLogger.calls.info("Remote video track received")
        Task { @MainActor in
            self.hasRemoteVideoTrack = true
            self.peerVideoEnabled = true
        }
        // The view layer will attach renderers via attachRemoteRenderer
    }

    func webRTCClientDidRemoveRemoteVideoTrack(_ client: WebRTCClient) {
        SanchrLogger.calls.info("Remote video track removed")
        Task { @MainActor in
            self.hasRemoteVideoTrack = false
        }
    }

    func webRTCClient(_ client: WebRTCClient, didChangeSignalingState state: RTCSignalingState) {
        SanchrLogger.calls.info("WebRTC signaling state: \(state.rawValue)")
    }
}
