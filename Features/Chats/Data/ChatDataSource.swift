import Foundation
import GRPC
import SanchrShared

/// Data source for chat-related gRPC service calls.
/// Wraps the MessagingService client with domain model mapping
/// and provides encrypted message send/receive orchestration.
final class ChatDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    /// Convenience accessor for the messaging async client from the gRPC manager.
    private var messagingClient: Sanchr_Messaging_MessagingServiceAsyncClientProtocol {
        grpcClient.messagingService
    }

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // MARK: - Start Direct Conversation

    /// Creates or retrieves a 1:1 conversation with the given recipient.
    func startDirectConversation(recipientID: String) async throws -> Sanchr_Messaging_Conversation {
        var request = Sanchr_Messaging_StartDirectConversationRequest()
        request.recipientID = recipientID

        SanchrLogger.chat.info(
            "ChatDataSource: startDirectConversation with \(recipientID.prefix(8))...")
        return try await messagingClient.startDirectConversation(request)
    }

    // MARK: - Send Message

    /// Sends an encrypted message to a conversation.
    /// The caller is responsible for encrypting the ciphertext per-device.
    func sendMessage(
        conversationID: String,
        deviceMessages: [Sanchr_Messaging_DeviceMessage],
        contentType: String = "text",
        expiresAfterSecs: Int64 = 0
    ) async throws -> Sanchr_Messaging_SendMessageResponse {
        var request = Sanchr_Messaging_SendMessageRequest()
        request.conversationID = conversationID
        request.deviceMessages = deviceMessages
        request.contentType = contentType
        request.expiresAfterSecs = expiresAfterSecs

        SanchrLogger.chat.info(
            "ChatDataSource: sendMessage to conversation \(conversationID.prefix(8))... (\(deviceMessages.count) device(s))"
        )
        return try await messagingClient.sendMessage(request)
    }

    // MARK: - Encrypted Message Orchestration

    /// Encrypts plaintext for all recipient devices and sends via gRPC.
    /// This is the high-level entry point for sending an E2EE message.
    func sendEncryptedMessage(
        conversationId: String,
        plaintext: Data,
        recipientIds: [String],
        signalSessionManager: SignalProtocolManagerProtocol,
        contentType: String = "text"
    ) async throws -> Sanchr_Messaging_SendMessageResponse {
        var allDeviceMessages: [Sanchr_Messaging_DeviceMessage] = []

        for recipientId in recipientIds {
            if let sessionManager = signalSessionManager as? SignalSessionManager {
                let deviceMessages = try await sessionManager.encryptForAllDevices(
                    plaintext: plaintext,
                    recipientId: recipientId
                )
                allDeviceMessages.append(contentsOf: deviceMessages)
            } else {
                throw AppError.encryptionFailed(
                    reason: "Signal multi-device manager is unavailable."
                )
            }
        }

        return try await sendMessage(
            conversationID: conversationId,
            deviceMessages: allDeviceMessages,
            contentType: contentType
        )
    }

    /// Decrypts an incoming EncryptedEnvelope to plaintext using the Signal Protocol.
    func decryptIncomingMessage(
        envelope: Sanchr_Messaging_EncryptedEnvelope,
        signalSessionManager: SignalProtocolManagerProtocol
    ) async throws -> Data {
        return try await signalSessionManager.decryptEnvelope(envelope)
    }

    // MARK: - Get Conversations

    /// Fetches all conversations for the authenticated user.
    func getConversations() async throws -> [Sanchr_Messaging_Conversation] {
        let request = Sanchr_Messaging_GetConversationsRequest()

        SanchrLogger.chat.info("ChatDataSource: getConversations")
        let response = try await messagingClient.getConversations(request)
        return response.conversations
    }

    // MARK: - Send Reaction

    /// Sends or removes a reaction on a message via gRPC.
    func sendReaction(
        messageID: String,
        conversationID: String,
        userID: String,
        emoji: String,
        removed: Bool
    ) async throws {
        var request = Sanchr_Messaging_Reaction()
        request.messageID = messageID
        request.conversationID = conversationID
        request.userID = userID
        request.emoji = emoji
        request.removed = removed
        request.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        SanchrLogger.chat.info(
            "ChatDataSource: sendReaction \(removed ? "remove" : "add") \(emoji) on \(messageID.prefix(8))..."
        )
        _ = try await messagingClient.sendReaction(request)
    }

    // MARK: - Delete Message

    /// Deletes a message from a conversation on the server.
    func deleteMessage(conversationID: String, messageID: String) async throws {
        var request = Sanchr_Messaging_DeleteMessageRequest()
        request.conversationID = conversationID
        request.messageID = messageID

        SanchrLogger.chat.info("ChatDataSource: deleteMessage \(messageID.prefix(8))...")
        _ = try await messagingClient.deleteMessage(request)
    }

    // MARK: - Sync Messages

    /// Syncs messages from the server since a given timestamp.
    /// Returns a GRPCAsyncResponseStream of encrypted envelopes.
    func syncMessages(sinceTimestamp: Int64) -> GRPCAsyncResponseStream<
        Sanchr_Messaging_EncryptedEnvelope
    > {
        var request = Sanchr_Messaging_SyncRequest()
        request.sinceTimestamp = sinceTimestamp

        SanchrLogger.chat.info("ChatDataSource: syncMessages since \(sinceTimestamp)")
        return messagingClient.syncMessages(request)
    }

    // MARK: - Message Stream (Bidi)

    /// Opens a bidirectional stream for real-time events (messages, typing, presence).
    func openMessageStream(
        clientEvents: AsyncStream<Sanchr_Messaging_ClientEvent>
    ) -> GRPCAsyncResponseStream<Sanchr_Messaging_ServerEvent> {
        SanchrLogger.chat.info("ChatDataSource: opening message stream")
        return messagingClient.messageStream(clientEvents)
    }

    // MARK: - Domain Model Mapping

    /// Maps a proto Conversation to the domain Conversation model.
    /// When a `contactsLookup` dictionary is provided, resolves participant display names
    /// and phone numbers from cached contacts instead of showing raw UUIDs.
    static func mapToDomainConversation(
        _ proto: Sanchr_Messaging_Conversation,
        contactsLookup: [String: User] = [:],
        localUserId: String? = nil
    ) -> Conversation {
        let conversationType: Conversation.ConversationType =
            proto.type == "group" ? .group : .oneToOne
        let serverParticipants = Dictionary(
            uniqueKeysWithValues: proto.participants.map { ($0.userID, $0) }
        )

        let participants = proto.participantIds.map { participantID -> User in
            let isLocal = participantID == localUserId

            if var cached = contactsLookup[participantID] {
                cached.isLocalUser = isLocal
                if cached.displayName.isEmpty,
                   let serverParticipant = serverParticipants[participantID],
                   !serverParticipant.displayName.isEmpty
                {
                    cached.displayName = serverParticipant.displayName
                }
                if cached.avatarURL == nil,
                   let serverParticipant = serverParticipants[participantID],
                   !serverParticipant.avatarURL.isEmpty
                {
                    cached.avatarURL = URL(string: serverParticipant.avatarURL)
                }
                return cached
            }

            if let serverParticipant = serverParticipants[participantID] {
                let displayName =
                    serverParticipant.displayName.isEmpty
                    ? (isLocal ? "You" : participantID)
                    : serverParticipant.displayName

                return User(
                    id: participantID,
                    phoneNumber: "",
                    displayName: displayName,
                    avatarURL: serverParticipant.avatarURL.isEmpty
                        ? nil
                        : URL(string: serverParticipant.avatarURL),
                    bio: nil,
                    isVerified: false,
                    lastSeen: nil,
                    identityKeyFingerprint: nil,
                    status: .offline,
                    isLocalUser: isLocal
                )
            }

            return User(
                id: participantID,
                phoneNumber: "",
                displayName: isLocal ? "You" : participantID,
                avatarURL: nil,
                bio: nil,
                isVerified: false,
                lastSeen: nil,
                identityKeyFingerprint: nil,
                status: .offline,
                isLocalUser: isLocal
            )
        }

        return Conversation(
            id: proto.id,
            participants: participants,
            lastMessage: nil,
            unreadCount: Int(proto.unreadCount),
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: conversationType,
            disappearingMessagesDuration: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
