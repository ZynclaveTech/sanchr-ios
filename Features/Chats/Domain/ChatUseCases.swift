import Foundation

/// Domain use cases for chat operations.
/// Each use case encapsulates a single chat operation with proper error handling.
enum ChatUseCases {

    // MARK: - Get Conversations Use Case

    /// Fetches the conversation list, merging server data with local cache.
    struct GetConversationsUseCase: Sendable {
        private let messageRepository: MessageRepositoryProtocol
        private let chatDataSource: ChatDataSource

        init(messageRepository: MessageRepositoryProtocol, chatDataSource: ChatDataSource) {
            self.messageRepository = messageRepository
            self.chatDataSource = chatDataSource
        }

        /// Fetches conversations from server, falls back to local cache on failure.
        func execute() async throws -> [Conversation] {
            SanchrLogger.chat.info("GetConversationsUseCase: fetching conversations")

            // Try server first
            do {
                let protoConversations = try await chatDataSource.getConversations()
                let conversations = protoConversations.map { ChatDataSource.mapToDomainConversation($0) }

                SanchrLogger.chat.info("Fetched \(conversations.count) conversations from server")
                return conversations
            } catch {
                SanchrLogger.chat.warning("Server fetch failed, falling back to local: \(error.localizedDescription)")
                // Fall back to local database
                return try await messageRepository.fetchConversations()
            }
        }
    }

    // MARK: - Send Message Use Case

    /// Sends an encrypted text message to a conversation.
    /// Handles Signal Protocol session establishment, per-device encryption,
    /// optimistic UI, and server confirmation.
    struct SendMessageUseCase: Sendable {
        private let messageRepository: MessageRepositoryProtocol
        private let signalSessionManager: SignalProtocolManagerProtocol
        private let chatDataSource: ChatDataSource

        init(
            messageRepository: MessageRepositoryProtocol,
            signalSessionManager: SignalProtocolManagerProtocol,
            chatDataSource: ChatDataSource
        ) {
            self.messageRepository = messageRepository
            self.signalSessionManager = signalSessionManager
            self.chatDataSource = chatDataSource
        }

        /// Sends a text message. Establishes encrypted sessions with all recipient devices if needed.
        func execute(text: String, conversationId: String, recipientId: String) async throws -> Message {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                throw AppError.unknown(underlying: "Cannot send an empty message.")
            }

            SanchrLogger.chat.info("SendMessageUseCase: sending to \(conversationId.prefix(8))...")

            // 1. Encode plaintext
            guard let plaintext = trimmedText.data(using: .utf8) else {
                throw AppError.encryptionFailed(reason: "Failed to encode message text.")
            }

            // 2. Encrypt for all recipient devices (establishes sessions as needed via X3DH)
            let deviceMessages: [Vync_Messaging_DeviceMessage]
            if let sessionManager = signalSessionManager as? SignalSessionManager {
                deviceMessages = try await sessionManager.encryptForAllDevices(
                    plaintext: plaintext,
                    recipientId: recipientId
                )
            } else {
                // Legacy fallback: encrypt for device 1 only
                if !signalSessionManager.hasSession(with: recipientId) {
                    try await signalSessionManager.establishSession(with: recipientId, deviceId: 1)
                }
                let ciphertext = try await signalSessionManager.encrypt(
                    plaintext: plaintext,
                    for: recipientId,
                    deviceId: 1
                )
                var dm = Vync_Messaging_DeviceMessage()
                dm.recipientID = recipientId
                dm.deviceID = 1
                dm.ciphertext = ciphertext
                deviceMessages = [dm]
            }

            // 3. Send via gRPC
            let response = try await chatDataSource.sendMessage(
                conversationID: conversationId,
                deviceMessages: deviceMessages,
                contentType: "text"
            )

            // 4. Return confirmed message with server timestamp
            let confirmedMessage = Message(
                id: response.messageID,
                conversationId: conversationId,
                senderId: "local", // TODO: Get from SessionService.currentUserId
                timestamp: Date(timeIntervalSince1970: TimeInterval(response.serverTimestamp) / 1000),
                content: .text(trimmedText),
                status: .sent,
                isOutgoing: true
            )

            SanchrLogger.chat.info("Message sent: \(response.messageID)")
            return confirmedMessage
        }
    }

    // MARK: - Delete Message Use Case

    /// Deletes a message locally and optionally on the server.
    struct DeleteMessageUseCase: Sendable {
        private let messageRepository: MessageRepositoryProtocol
        private let chatDataSource: ChatDataSource

        init(messageRepository: MessageRepositoryProtocol, chatDataSource: ChatDataSource) {
            self.messageRepository = messageRepository
            self.chatDataSource = chatDataSource
        }

        /// Deletes a message. If `forEveryone` is true, also deletes on the server.
        func execute(messageId: String, conversationId: String, forEveryone: Bool) async throws {
            SanchrLogger.chat.info("DeleteMessageUseCase: deleting \(messageId.prefix(8))... forEveryone=\(forEveryone)")

            // Delete from server if for everyone
            if forEveryone {
                try await chatDataSource.deleteMessage(
                    conversationID: conversationId,
                    messageID: messageId
                )
            }

            // Always delete locally
            try await messageRepository.deleteMessage(id: messageId, forEveryone: forEveryone)

            SanchrLogger.chat.info("Message deleted: \(messageId.prefix(8))...")
        }
    }

    // MARK: - Mark As Read Use Case

    /// Marks all messages in a conversation as read and sends read receipts.
    struct MarkAsReadUseCase: Sendable {
        private let messageRepository: MessageRepositoryProtocol
        private let chatDataSource: ChatDataSource

        init(messageRepository: MessageRepositoryProtocol, chatDataSource: ChatDataSource) {
            self.messageRepository = messageRepository
            self.chatDataSource = chatDataSource
        }

        func execute(conversationId: String, upToMessageId: String) async throws {
            SanchrLogger.chat.info("MarkAsReadUseCase: marking \(conversationId.prefix(8)) read up to \(upToMessageId.prefix(8))")

            // Update local state
            try await messageRepository.markAsRead(
                conversationId: conversationId,
                upToMessageId: upToMessageId
            )

            // Send read receipt to server (best-effort)
            do {
                try await chatDataSource.sendReceipt(
                    conversationID: conversationId,
                    messageID: upToMessageId,
                    status: "read"
                )
            } catch {
                SanchrLogger.chat.warning("Failed to send read receipt: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Fetch Conversations (legacy, kept for compatibility)

    struct FetchConversations: Sendable {
        private let messageRepository: MessageRepositoryProtocol

        init(messageRepository: MessageRepositoryProtocol) {
            self.messageRepository = messageRepository
        }

        func execute() async throws -> [Conversation] {
            try await messageRepository.fetchConversations()
        }
    }

    // MARK: - Mark As Read (legacy)

    struct MarkAsRead: Sendable {
        private let messageRepository: MessageRepositoryProtocol

        init(messageRepository: MessageRepositoryProtocol) {
            self.messageRepository = messageRepository
        }

        func execute(conversationId: String, upToMessageId: String) async throws {
            try await messageRepository.markAsRead(
                conversationId: conversationId,
                upToMessageId: upToMessageId
            )
        }
    }

    // MARK: - Delete Message (legacy)

    struct DeleteMessage: Sendable {
        private let messageRepository: MessageRepositoryProtocol

        init(messageRepository: MessageRepositoryProtocol) {
            self.messageRepository = messageRepository
        }

        func execute(messageId: String, forEveryone: Bool) async throws {
            try await messageRepository.deleteMessage(id: messageId, forEveryone: forEveryone)
        }
    }
}
