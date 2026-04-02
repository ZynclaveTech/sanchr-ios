import Foundation

/// Use case for sending an encrypted message.
/// Orchestrates encryption, sending, and local persistence.
struct SendMessageUseCase: Sendable {
    private let messageRepository: MessageRepositoryProtocol
    private let signalProtocol: SignalProtocolManagerProtocol

    init(messageRepository: MessageRepositoryProtocol, signalProtocol: SignalProtocolManagerProtocol) {
        self.messageRepository = messageRepository
        self.signalProtocol = signalProtocol
    }

    /// Sends a text message to the specified conversation.
    func execute(text: String, conversationId: String, recipientId: String) async throws -> Message {
        // 1. Ensure encrypted session exists
        if !signalProtocol.hasSession(with: recipientId) {
            let preKeyBundle = try await messageRepository.fetchPreKeyBundle(userId: recipientId)
            try await signalProtocol.establishSession(with: recipientId, preKeyBundle: preKeyBundle)
        }

        // 2. Create message
        let message = Message.textMessage(
            conversationId: conversationId,
            senderId: "local", // TODO: Get from session
            text: text,
            isOutgoing: true
        )

        // 3. Send via repository (handles encryption internally)
        return try await messageRepository.sendMessage(message)
    }
}
