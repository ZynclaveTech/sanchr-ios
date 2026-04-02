import Foundation

/// Use case for sending an encrypted message.
/// Orchestrates Signal Protocol encryption, sending, and local persistence.
///
/// Note: The primary send flow now lives in `ChatUseCases.SendMessageUseCase` which
/// handles per-device encryption. This shared use case is kept for backward compatibility
/// with code paths that go through `MessageRepository`.
struct SendMessageUseCase: Sendable {
    private let messageRepository: MessageRepositoryProtocol
    private let signalProtocol: SignalProtocolManagerProtocol

    init(messageRepository: MessageRepositoryProtocol, signalProtocol: SignalProtocolManagerProtocol) {
        self.messageRepository = messageRepository
        self.signalProtocol = signalProtocol
    }

    /// Sends a text message to the specified conversation.
    func execute(text: String, conversationId: String, recipientId: String) async throws -> Message {
        // 1. Ensure encrypted session exists (establish via X3DH if needed)
        if !signalProtocol.hasSession(with: recipientId) {
            try await signalProtocol.establishSession(with: recipientId, deviceId: 1)
        }

        // 2. Create message
        let message = Message.textMessage(
            conversationId: conversationId,
            senderId: "local", // TODO: Get from SessionService.currentUserId
            text: text,
            isOutgoing: true
        )

        // 3. Send via repository (handles encryption internally)
        return try await messageRepository.sendMessage(message)
    }
}
