import AVFoundation
import Foundation
import SanchrShared
@preconcurrency import WebRTC

// MARK: - WebRTC Client Delegate

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didReceiveLocalCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack)
    func webRTCClientDidRemoveRemoteVideoTrack(_ client: WebRTCClient)
    func webRTCClient(_ client: WebRTCClient, didChangeSignalingState state: RTCSignalingState)
}

// MARK: - WebRTCClient

final class WebRTCClient: NSObject {

    // MARK: - Properties

    weak var delegate: WebRTCClientDelegate?

    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        // Prefer H264 for hardware acceleration on iOS
        if let h264 = RTCDefaultVideoEncoderFactory.supportedCodecs()
            .first(where: { $0.name == kRTCH264CodecName })
        {
            encoderFactory.preferredCodec = h264
        }
        return RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }()

    private var peerConnection: RTCPeerConnection?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: FilteredVideoCapturer?

    /// Read-only setup state, so a failed call setup can be checked for
    /// leaks without reaching into the tracks.
    var hasPeerConnection: Bool { peerConnection != nil }
    var hasLocalMedia: Bool { localAudioTrack != nil || localVideoTrack != nil }
    private var localVideoSource: RTCVideoSource?
    private var pendingRemoteIceCandidates: [RTCIceCandidate] = []
    private var remoteRenderers: [RTCVideoRenderer] = []

    private var isMuted: Bool = false
    private var isSpeakerOn: Bool = false
    private var isUsingFrontCamera: Bool = true
    private var isVideoEnabled: Bool = false

    private let rtcQueue = DispatchQueue(label: "io.sanchr.webrtc", qos: .userInitiated)

    // MARK: - Init

    override init() {
        super.init()
        SanchrLogger.calls.info("WebRTCClient initialized with H264 codec preference")
    }

    // MARK: - Connection Setup

    /// Configures the peer connection with the provided ICE (STUN/TURN) servers.
    func configure(iceServers: [RTCIceServer]) {
        SanchrLogger.calls.info(
            "Configuring peer connection with \(iceServers.count) ICE server(s)")

        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.tcpCandidatePolicy = .disabled
        config.candidateNetworkPolicy = .all
        config.iceTransportPolicy = .all

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )

        guard
            let pc = Self.factory.peerConnection(
                with: config,
                constraints: constraints,
                delegate: self
            )
        else {
            SanchrLogger.calls.error("Failed to create RTCPeerConnection")
            return
        }

        self.peerConnection = pc
        pendingRemoteIceCandidates.removeAll()
        SanchrLogger.calls.info("Peer connection created successfully")
    }

    // MARK: - Media

    /// Adds local audio and optionally video tracks to the peer connection.
    func startLocalMedia(isVideo: Bool) {
        guard let pc = peerConnection else {
            SanchrLogger.calls.error("startLocalMedia called without peer connection")
            return
        }

        // Audio track
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let audioSource = Self.factory.audioSource(with: audioConstraints)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "sanchr-audio-0")
        audioTrack.isEnabled = true
        self.localAudioTrack = audioTrack
        pc.add(audioTrack, streamIds: ["sanchr-stream-0"])
        SanchrLogger.calls.info("Local audio track added")

        // Video track
        if isVideo {
            _ = setVideoEnabled(true)
        } else {
            self.isVideoEnabled = false
        }

        configureAudioSession()
    }

    /// Stops all local media tracks and releases capture resources.
    func stopLocalMedia() {
        SanchrLogger.calls.info("Stopping local media")
        videoCapturer?.stopCapture()
        localAudioTrack?.isEnabled = false
        localVideoTrack?.isEnabled = false
    }

    /// Toggles the mute state of the local audio track. Returns the new muted state.
    @discardableResult
    func toggleMute() -> Bool {
        setMuted(!isMuted)
    }

    /// Sets the mute state of the local audio track. Returns the applied muted state.
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        isMuted = muted
        localAudioTrack?.isEnabled = !muted
        SanchrLogger.calls.info("Mute set: \(self.isMuted)")
        return isMuted
    }

    /// Toggles the speaker output. Returns the new speaker-on state.
    @discardableResult
    func toggleSpeaker() -> Bool {
        setSpeakerEnabled(!isSpeakerOn)
    }

    /// Sets the audio route. `true` forces speaker; `false` returns to the receiver/earpiece route.
    @discardableResult
    func setSpeakerEnabled(_ enabled: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
            isSpeakerOn = enabled
            SanchrLogger.calls.info("Speaker set: \(self.isSpeakerOn)")
        } catch {
            SanchrLogger.calls.error(
                "Failed to set speaker=\(enabled): \(error.localizedDescription)")
        }
        return isSpeakerOn
    }

    /// Switches between front and back camera. Returns true if now using front camera.
    @discardableResult
    func toggleCamera() -> Bool {
        isUsingFrontCamera.toggle()
        guard let capturer = videoCapturer else { return isUsingFrontCamera }
        capturer.stopCapture()
        startCameraCapture(capturer: capturer)
        SanchrLogger.calls.info("Camera switched to \(self.isUsingFrontCamera ? "front" : "back")")
        return isUsingFrontCamera
    }

    /// Enables or disables the local video track. Returns the new video-enabled state.
    @discardableResult
    func toggleVideo() -> Bool {
        setVideoEnabled(!isVideoEnabled)
    }

    /// Enables or disables the local video track. If no video track exists yet, one is added.
    @discardableResult
    func setVideoEnabled(_ enabled: Bool) -> Bool {
        if enabled, isVideoEnabled, localVideoTrack != nil {
            return true
        }

        if enabled {
            guard ensureLocalVideoTrack() else {
                isVideoEnabled = false
                return false
            }
            localVideoTrack?.isEnabled = true
            if let capturer = videoCapturer {
                startCameraCapture(capturer: capturer)
            }
            isVideoEnabled = true
        } else {
            localVideoTrack?.isEnabled = false
            videoCapturer?.stopCapture()
            isVideoEnabled = false
        }
        SanchrLogger.calls.info("Video set: \(self.isVideoEnabled)")
        return isVideoEnabled
    }

    /// Sets the real-time video filter applied to outgoing frames.
    /// Safe to call at any time during a call; takes effect on the next frame.
    func setVideoFilter(_ filter: VideoFilter) {
        videoCapturer?.currentFilter = filter
        SanchrLogger.calls.info("Video filter set to: \(filter.displayName)")
    }

    // MARK: - Signaling

    /// Creates an SDP offer for initiating a call.
    func createOffer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw AppError.callConnectionFailed
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue,
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { sdp, error in
                if let error {
                    SanchrLogger.calls.error(
                        "Failed to create offer: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else if let sdp {
                    SanchrLogger.calls.info("SDP offer created")
                    nonisolated(unsafe) let sendableSdp = sdp
                    continuation.resume(returning: sendableSdp)
                } else {
                    continuation.resume(throwing: AppError.callConnectionFailed)
                }
            }
        }
    }

    /// Creates an SDP answer for responding to an incoming call.
    func createAnswer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw AppError.callConnectionFailed
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue,
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: constraints) { sdp, error in
                if let error {
                    SanchrLogger.calls.error(
                        "Failed to create answer: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else if let sdp {
                    SanchrLogger.calls.info("SDP answer created")
                    nonisolated(unsafe) let sendableSdp = sdp
                    continuation.resume(returning: sendableSdp)
                } else {
                    continuation.resume(throwing: AppError.callConnectionFailed)
                }
            }
        }
    }

    /// Sets the local session description on the peer connection.
    func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else {
            throw AppError.callConnectionFailed
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error {
                    SanchrLogger.calls.error(
                        "Failed to set local description: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else {
                    SanchrLogger.calls.info("Local description set: \(sdp.type.rawValue)")
                    continuation.resume()
                }
            }
        }
    }

    /// Sets the remote session description on the peer connection.
    func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else {
            throw AppError.callConnectionFailed
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    SanchrLogger.calls.error(
                        "Failed to set remote description: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else {
                    SanchrLogger.calls.info("Remote description set: \(sdp.type.rawValue)")
                    continuation.resume()
                }
            }
        }
        try await flushPendingRemoteIceCandidates()
    }

    /// Adds a remote ICE candidate to the peer connection.
    func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else {
            throw AppError.callConnectionFailed
        }
        guard pc.remoteDescription != nil else {
            pendingRemoteIceCandidates.append(candidate)
            SanchrLogger.calls.info(
                "Buffered remote ICE candidate until remote description is set")
            return
        }
        try await addIceCandidateNow(candidate)
    }

    private func addIceCandidateNow(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else {
            throw AppError.callConnectionFailed
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error {
                    SanchrLogger.calls.error(
                        "Failed to add ICE candidate: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func flushPendingRemoteIceCandidates() async throws {
        guard peerConnection?.remoteDescription != nil else { return }
        let candidates = pendingRemoteIceCandidates
        pendingRemoteIceCandidates.removeAll()
        for candidate in candidates {
            try await addIceCandidateNow(candidate)
        }
        if !candidates.isEmpty {
            SanchrLogger.calls.info("Flushed \(candidates.count) buffered remote ICE candidates")
        }
    }

    // MARK: - DTLS Fingerprint

    /// Extracts the DTLS fingerprint from an SDP description.
    /// Returns a string like "sha-256 AA:BB:CC:..." or nil if the line is missing.
    static func extractDtlsFingerprint(from sdp: RTCSessionDescription) -> String? {
        let prefix = "a=fingerprint:"
        for line in sdp.sdp.components(separatedBy: CharacterSet.newlines) {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Video Rendering

    /// Attaches a renderer (e.g. RTCMTLVideoView) to the local video track.
    func attachLocalRenderer(_ renderer: RTCVideoRenderer) {
        localVideoTrack?.add(renderer)
    }

    /// Detaches a renderer from the local video track.
    func detachLocalRenderer(_ renderer: RTCVideoRenderer) {
        localVideoTrack?.remove(renderer)
    }

    /// Attaches a renderer to the remote video track.
    func attachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        if !remoteRenderers.contains(where: { ($0 as AnyObject) === (renderer as AnyObject) }) {
            remoteRenderers.append(renderer)
        }
        remoteVideoTrack?.add(renderer)
    }

    /// Detaches a renderer from the remote video track.
    func detachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        remoteVideoTrack?.remove(renderer)
        remoteRenderers.removeAll { ($0 as AnyObject) === (renderer as AnyObject) }
    }

    // MARK: - Cleanup

    /// Closes the peer connection and releases all resources.
    func close() {
        SanchrLogger.calls.info("Closing WebRTC peer connection")
        videoCapturer?.stopCapture()
        videoCapturer = nil
        localAudioTrack = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        localVideoSource = nil
        pendingRemoteIceCandidates.removeAll()
        remoteRenderers.removeAll()
        peerConnection?.close()
        peerConnection = nil
        isMuted = false
        isSpeakerOn = false
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        releaseAudioSession()
        isUsingFrontCamera = true
        isVideoEnabled = false
    }

    /// Hands the audio session back when a call is over.
    ///
    /// `configureAudioSession` claimed the session for the call and nothing
    /// ever gave it back. Two consequences, both of which outlived the call:
    ///
    /// - Whatever was playing before — music, a podcast — never resumed,
    ///   because the session was never deactivated with
    ///   `notifyOthersOnDeactivation`.
    /// - Category and mode are sticky. Deactivation alone does not clear them,
    ///   so the session read as `.playAndRecord` / `.voiceChat` for the rest of
    ///   the process. Anything asking "is a call happening?" by inspecting the
    ///   session got the wrong answer from the first call onwards, which is
    ///   exactly how gallery video ended up silent after any call.
    ///
    /// Taken under `RTCAudioSession`'s lock so WebRTC cannot reconfigure the
    /// session while it is being handed back, and entirely best-effort: a call
    /// that has already ended must not be able to fail here.
    private func releaseAudioSession() {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        defer { rtcSession.unlockForConfiguration() }

        // Before deactivating, so WebRTC stops touching a session that is
        // about to go away.
        rtcSession.isAudioEnabled = false

        let session = AVAudioSession.sharedInstance()
        do {
            // Deactivate first: the notification is what lets other apps pick
            // up again, and it has to happen while the session is still ours.
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // CallKit may already have deactivated it, which is fine — the
            // category reset below is the part that still matters.
            SanchrLogger.calls.info(
                "Audio session was already inactive: \(error.localizedDescription)"
            )
        }

        do {
            try session.setCategory(.ambient, mode: .default)
        } catch {
            SanchrLogger.calls.warning(
                "Could not reset the audio category after the call: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Private Helpers

    private func ensureLocalVideoTrack() -> Bool {
        if localVideoTrack != nil {
            return true
        }

        guard let pc = peerConnection else {
            SanchrLogger.calls.error("setVideoEnabled called without peer connection")
            return false
        }

        let videoSource = Self.factory.videoSource()
        self.localVideoSource = videoSource

        #if targetEnvironment(simulator)
            // Simulator does not support camera capture, but the track is still useful
            // for SDP negotiation and renderer plumbing.
            SanchrLogger.calls.warning("Simulator detected: video capture unavailable")
        #else
            let capturer = FilteredVideoCapturer(delegate: videoSource)
            self.videoCapturer = capturer
        #endif

        let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "sanchr-video-0")
        videoTrack.isEnabled = true
        self.localVideoTrack = videoTrack
        pc.add(videoTrack, streamIds: ["sanchr-stream-0"])
        SanchrLogger.calls.info("Local video track added")
        return true
    }

    private func startCameraCapture(capturer: FilteredVideoCapturer) {
        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position)
        else {
            SanchrLogger.calls.error("No camera found for position \(position == .front ? "front" : "back")")
            return
        }
        guard let format = device.formats
            .filter({
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width <= 1280 && d.height <= 720
            })
            .max(by: {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return (a.width * a.height) < (b.width * b.height)
            }) ?? device.formats.first else {
            SanchrLogger.calls.error("No suitable format found")
            return
        }
        capturer.startCapture(with: device, format: format, fps: 30)
        SanchrLogger.calls.info("Camera capture started: \(position == .front ? "front" : "back")")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)
            SanchrLogger.calls.info("Audio session configured for voice chat")
        } catch {
            SanchrLogger.calls.error(
                "Failed to configure audio session: \(error.localizedDescription)")
        }
        _ = setSpeakerEnabled(isSpeakerOn)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
    ) {
        SanchrLogger.calls.info("Signaling state changed: \(stateChanged.rawValue)")
        delegate?.webRTCClient(self, didChangeSignalingState: stateChanged)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        SanchrLogger.calls.info(
            "Remote stream added with \(stream.videoTracks.count) video track(s)")
        if let videoTrack = stream.videoTracks.first {
            self.remoteVideoTrack = videoTrack
            for renderer in remoteRenderers {
                videoTrack.add(renderer)
            }
            delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let videoTrack = rtpReceiver.track as? RTCVideoTrack else { return }
        SanchrLogger.calls.info("Remote video track added via RTP receiver")
        self.remoteVideoTrack = videoTrack
        for renderer in remoteRenderers {
            videoTrack.add(renderer)
        }
        delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        SanchrLogger.calls.info("Remote stream removed")
        guard !stream.videoTracks.isEmpty || remoteVideoTrack != nil else { return }
        if let remoteVideoTrack {
            for renderer in remoteRenderers {
                remoteVideoTrack.remove(renderer)
            }
        }
        self.remoteVideoTrack = nil
        delegate?.webRTCClientDidRemoveRemoteVideoTrack(self)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        SanchrLogger.calls.info("Peer connection should negotiate")
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
    ) {
        SanchrLogger.calls.info("ICE connection state changed: \(newState.rawValue)")
        delegate?.webRTCClient(self, didChangeConnectionState: newState)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
    ) {
        SanchrLogger.calls.info("ICE gathering state changed: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate)
    {
        SanchrLogger.calls.info("ICE candidate generated: \(candidate.sdpMid ?? "nil")")
        delegate?.webRTCClient(self, didReceiveLocalCandidate: candidate)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
    ) {
        SanchrLogger.calls.info("ICE candidates removed: \(candidates.count)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        SanchrLogger.calls.info("Data channel opened: \(dataChannel.label)")
    }
}
