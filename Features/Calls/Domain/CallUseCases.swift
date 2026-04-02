import Foundation

/// Domain use cases for call operations.
enum CallUseCases {

    /// Initiates an outgoing encrypted call.
    struct StartCall: Sendable {
        private let callManager: CallManagerProtocol
        private let signalProtocol: SignalProtocolManagerProtocol

        init(callManager: CallManagerProtocol, signalProtocol: SignalProtocolManagerProtocol) {
            self.callManager = callManager
            self.signalProtocol = signalProtocol
        }

        func execute(userId: String, hasVideo: Bool) async throws {
            // Ensure encrypted session exists before initiating call
            guard signalProtocol.hasSession(with: userId) else {
                throw AppError.sessionNotEstablished
            }
            try await callManager.startOutgoingCall(to: userId, hasVideo: hasVideo)
        }
    }

    /// Answers an incoming call.
    struct AnswerCall: Sendable {
        private let callManager: CallManagerProtocol

        init(callManager: CallManagerProtocol) {
            self.callManager = callManager
        }

        func execute(callId: String) async throws {
            try await callManager.answerIncomingCall(callId: callId)
        }
    }

    /// Ends the current call.
    struct EndCall: Sendable {
        private let callManager: CallManagerProtocol

        init(callManager: CallManagerProtocol) {
            self.callManager = callManager
        }

        func execute(callId: String) async throws {
            try await callManager.endCall(callId: callId)
        }
    }
}
