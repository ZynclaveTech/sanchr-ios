import Foundation
import CallKit
import AVFoundation

/// Protocol for call lifecycle management.
protocol CallManagerProtocol: AnyObject, Sendable {
    func startOutgoingCall(to userId: String, hasVideo: Bool) async throws
    func answerIncomingCall(callId: String) async throws
    func endCall(callId: String) async throws
    func reportIncomingCall(callId: String, callerName: String, hasVideo: Bool) async throws
    func toggleMute() async
    func toggleSpeaker() async
    var currentCallState: CallState { get }
}

/// Current state of the active call.
enum CallState: Sendable {
    case idle
    case outgoing(userId: String)
    case incoming(callId: String, callerName: String)
    case connecting
    case active(startTime: Date)
    case ended
}

/// Manages call lifecycle with CallKit and WebRTC integration.
final class CallManager: NSObject, CallManagerProtocol, @unchecked Sendable {
    private let webRTCClient: WebRTCClientProtocol
    private let callController = CXCallController()
    private let provider: CXProvider

    private(set) var currentCallState: CallState = .idle
    private var activeCallUUID: UUID?

    init(webRTCClient: WebRTCClientProtocol) {
        self.webRTCClient = webRTCClient

        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.iconTemplateImageData = nil // TODO: Set app icon
        config.ringtoneSound = nil // TODO: Custom ringtone
        config.supportedHandleTypes = [.phoneNumber, .generic]
        self.provider = CXProvider(configuration: config)

        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func startOutgoingCall(to userId: String, hasVideo: Bool) async throws {
        SanchrLogger.calls.info("Starting outgoing call to \(userId)")

        let uuid = UUID()
        activeCallUUID = uuid
        currentCallState = .outgoing(userId: userId)

        let handle = CXHandle(type: .generic, value: userId)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = hasVideo

        let transaction = CXTransaction(action: action)
        try await callController.request(transaction)
    }

    func answerIncomingCall(callId: String) async throws {
        guard let uuid = activeCallUUID else { return }
        SanchrLogger.calls.info("Answering incoming call \(callId)")

        let action = CXAnswerCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        try await callController.request(transaction)
    }

    func endCall(callId: String) async throws {
        guard let uuid = activeCallUUID else { return }
        SanchrLogger.calls.info("Ending call \(callId)")

        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        try await callController.request(transaction)

        currentCallState = .ended
        activeCallUUID = nil
    }

    func reportIncomingCall(callId: String, callerName: String, hasVideo: Bool) async throws {
        SanchrLogger.calls.info("Reporting incoming call from \(callerName)")

        let uuid = UUID()
        activeCallUUID = uuid
        currentCallState = .incoming(callId: callId, callerName: callerName)

        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo
        update.supportsGrouping = false
        update.supportsHolding = false

        try await provider.reportNewIncomingCall(with: uuid, update: update)
    }

    func toggleMute() async {
        // TODO: Toggle mute via CXSetMutedCallAction
    }

    func toggleSpeaker() async {
        // TODO: Toggle audio route via AVAudioSession
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        SanchrLogger.calls.info("CallKit provider reset")
        currentCallState = .idle
        activeCallUUID = nil
        Task { await webRTCClient.disconnect() }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        SanchrLogger.calls.info("CallKit: start call action")
        // TODO: Configure audio session, create WebRTC offer
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        SanchrLogger.calls.info("CallKit: answer call action")
        // TODO: Configure audio session, create WebRTC answer
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        SanchrLogger.calls.info("CallKit: end call action")
        Task { await webRTCClient.disconnect() }
        currentCallState = .ended
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        SanchrLogger.calls.info("Audio session activated")
        // TODO: Start WebRTC audio
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        SanchrLogger.calls.info("Audio session deactivated")
    }
}
