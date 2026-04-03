import Foundation
import AVFoundation
import WebRTC

// MARK: - WebRTC Client Delegate

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didReceiveLocalCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack)
    func webRTCClient(_ client: WebRTCClient, didChangeSignalingState state: RTCSignalingState)
}

// MARK: - WebRTCClient

final class WebRTCClient: NSObject {

    // MARK: - Properties

    weak var delegate: WebRTCClientDelegate?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        // Prefer H264 for hardware acceleration on iOS
        if let h264 = RTCDefaultVideoEncoderFactory.supportedCodecs()
            .first(where: { $0.name == kRTCH264CodecName }) {
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
    private var videoCapturer: RTCCameraVideoCapturer?
    private var localVideoSource: RTCVideoSource?

    private var isMuted: Bool = false
    private var isSpeakerOn: Bool = false
    private var isUsingFrontCamera: Bool = true
    private var isVideoEnabled: Bool = true

    private let rtcQueue = DispatchQueue(label: "io.sanchr.webrtc", qos: .userInitiated)

    // MARK: - Init

    override init() {
        super.init()
        SanchrLogger.calls.info("WebRTCClient initialized with H264 codec preference")
    }

    // MARK: - Connection Setup

    /// Configures the peer connection with the provided ICE (STUN/TURN) servers.
    func configure(iceServers: [RTCIceServer]) {
        SanchrLogger.calls.info("Configuring peer connection with \(iceServers.count) ICE server(s)")

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

        guard let pc = Self.factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            SanchrLogger.calls.error("Failed to create RTCPeerConnection")
            return
        }

        self.peerConnection = pc
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
            let videoSource = Self.factory.videoSource()
            self.localVideoSource = videoSource

            #if targetEnvironment(simulator)
            // Simulator does not support camera capture
            SanchrLogger.calls.warning("Simulator detected: video capture unavailable")
            #else
            let capturer = RTCCameraVideoCapturer(delegate: videoSource)
            self.videoCapturer = capturer
            startCameraCapture(capturer: capturer)
            #endif

            let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "sanchr-video-0")
            videoTrack.isEnabled = true
            self.localVideoTrack = videoTrack
            self.isVideoEnabled = true
            pc.add(videoTrack, streamIds: ["sanchr-stream-0"])
            SanchrLogger.calls.info("Local video track added")
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
        isMuted.toggle()
        localAudioTrack?.isEnabled = !isMuted
        SanchrLogger.calls.info("Mute toggled: \(self.isMuted)")
        return isMuted
    }

    /// Toggles the speaker output. Returns the new speaker-on state.
    @discardableResult
    func toggleSpeaker() -> Bool {
        isSpeakerOn.toggle()
        let session = AVAudioSession.sharedInstance()
        do {
            if isSpeakerOn {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            SanchrLogger.calls.error("Failed to toggle speaker: \(error.localizedDescription)")
        }
        SanchrLogger.calls.info("Speaker toggled: \(self.isSpeakerOn)")
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
        isVideoEnabled.toggle()
        localVideoTrack?.isEnabled = isVideoEnabled
        if !isVideoEnabled {
            videoCapturer?.stopCapture()
        } else if let capturer = videoCapturer {
            startCameraCapture(capturer: capturer)
        }
        SanchrLogger.calls.info("Video toggled: \(self.isVideoEnabled)")
        return isVideoEnabled
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
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { sdp, error in
                if let error {
                    SanchrLogger.calls.error("Failed to create offer: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else if let sdp {
                    SanchrLogger.calls.info("SDP offer created")
                    continuation.resume(returning: sdp)
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
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: constraints) { sdp, error in
                if let error {
                    SanchrLogger.calls.error("Failed to create answer: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else if let sdp {
                    SanchrLogger.calls.info("SDP answer created")
                    continuation.resume(returning: sdp)
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error {
                    SanchrLogger.calls.error("Failed to set local description: \(error.localizedDescription)")
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error {
                    SanchrLogger.calls.error("Failed to set remote description: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else {
                    SanchrLogger.calls.info("Remote description set: \(sdp.type.rawValue)")
                    continuation.resume()
                }
            }
        }
    }

    /// Adds a remote ICE candidate to the peer connection.
    func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else {
            throw AppError.callConnectionFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error {
                    SanchrLogger.calls.error("Failed to add ICE candidate: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError.callConnectionFailed)
                } else {
                    continuation.resume()
                }
            }
        }
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
        remoteVideoTrack?.add(renderer)
    }

    /// Detaches a renderer from the remote video track.
    func detachRemoteRenderer(_ renderer: RTCVideoRenderer) {
        remoteVideoTrack?.remove(renderer)
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
        peerConnection?.close()
        peerConnection = nil
        isMuted = false
        isSpeakerOn = false
        isUsingFrontCamera = true
        isVideoEnabled = true
    }

    // MARK: - Private Helpers

    private func startCameraCapture(capturer: RTCCameraVideoCapturer) {
        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices()
            .first(where: { $0.position == position }) else {
            SanchrLogger.calls.error("No camera device found for position: \(String(describing: position))")
            return
        }

        // Select the closest format to 640x480 at 30fps
        let targetWidth: Int32 = 640
        let targetHeight: Int32 = 480
        let targetFps: Int32 = 30

        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let selectedFormat = formats
            .sorted { a, b in
                let dimA = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let dimB = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                let diffA = abs(dimA.width - targetWidth) + abs(dimA.height - targetHeight)
                let diffB = abs(dimB.width - targetWidth) + abs(dimB.height - targetHeight)
                return diffA < diffB
            }
            .first ?? formats.first

        guard let format = selectedFormat else {
            SanchrLogger.calls.error("No suitable camera format found")
            return
        }

        let fpsRanges = format.videoSupportedFrameRateRanges
        let selectedFps = fpsRanges
            .sorted { abs(Int32($0.maxFrameRate) - targetFps) < abs(Int32($1.maxFrameRate) - targetFps) }
            .first
            .map { min(Int(targetFps), Int($0.maxFrameRate)) } ?? Int(targetFps)

        capturer.startCapture(with: device, format: format, fps: selectedFps)
        SanchrLogger.calls.info("Camera capture started: \(device.localizedName) @ \(selectedFps)fps")
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
            SanchrLogger.calls.info("Audio session configured for voice chat")
        } catch {
            SanchrLogger.calls.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        SanchrLogger.calls.info("Signaling state changed: \(stateChanged.rawValue)")
        delegate?.webRTCClient(self, didChangeSignalingState: stateChanged)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        SanchrLogger.calls.info("Remote stream added with \(stream.videoTracks.count) video track(s)")
        if let videoTrack = stream.videoTracks.first {
            self.remoteVideoTrack = videoTrack
            delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        SanchrLogger.calls.info("Remote stream removed")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        SanchrLogger.calls.info("Peer connection should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        SanchrLogger.calls.info("ICE connection state changed: \(newState.rawValue)")
        delegate?.webRTCClient(self, didChangeConnectionState: newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        SanchrLogger.calls.info("ICE gathering state changed: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        SanchrLogger.calls.info("ICE candidate generated: \(candidate.sdpMid ?? "nil")")
        delegate?.webRTCClient(self, didReceiveLocalCandidate: candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        SanchrLogger.calls.info("ICE candidates removed: \(candidates.count)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        SanchrLogger.calls.info("Data channel opened: \(dataChannel.label)")
    }
}
