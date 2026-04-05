import Foundation
import GRPC

/// Data source for chat-related gRPC service calls.
/// Wraps the MessagingService client with domain model mapping
/// and provides encrypted message send/receive orchestration.
final class ChatDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    /// Convenience accessor for the messaging async client from the gRPC manager.
    private var messagingClient: Vync_Messaging_MessagingServiceAsyncClientProtocol {
        grpcClient.messagingService
    }

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // MARK: - Start Direct Conversation

    /// Creates or retrieves a 1:1 conversation with the given recipient.
    func startDirectConversation(recipientID: String) async throws -> Vync_Messaging_Conversation {
        var request = Vync_Messaging_StartDirectConversationRequest()
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
        deviceMessages: [Vync_Messaging_DeviceMessage],
        contentType: String = "text",
        expiresAfterSecs: Int64 = 0
    ) async throws -> Vync_Messaging_SendMessageResponse {
        var request = Vync_Messaging_SendMessageRequest()
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
        signalSessionManager: SignalProtocolManagerProtocol
    ) async throws -> Vync_Messaging_SendMessageResponse {
        var allDeviceMessages: [Vync_Messaging_DeviceMessage] = []

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
            contentType: "text"
        )
    }

    /// Decrypts an incoming EncryptedEnvelope to plaintext using the Signal Protocol.
    func decryptIncomingMessage(
        envelope: Vync_Messaging_EncryptedEnvelope,
        signalSessionManager: SignalProtocolManagerProtocol
    ) async throws -> Data {
        return try await signalSessionManager.decryptEnvelope(envelope)
    }

    // MARK: - Get Conversations

    /// Fetches all conversations for the authenticated user.
    func getConversations() async throws -> [Vync_Messaging_Conversation] {
        let request = Vync_Messaging_GetConversationsRequest()

        SanchrLogger.chat.info("ChatDataSource: getConversations")
        let response = try await messagingClient.getConversations(request)
        return response.conversations
    }

    // MARK: - Delete Message

    /// Deletes a message from a conversation on the server.
    func deleteMessage(conversationID: String, messageID: String) async throws {
        var request = Vync_Messaging_DeleteMessageRequest()
        request.conversationID = conversationID
        request.messageID = messageID

        SanchrLogger.chat.info("ChatDataSource: deleteMessage \(messageID.prefix(8))...")
        _ = try await messagingClient.deleteMessage(request)
    }

    // MARK: - Send Receipt

    /// Sends a delivery/read receipt for a message.
    func sendReceipt(conversationID: String, messageID: String, status: String) async throws {
        var request = Vync_Messaging_ReceiptRequest()
        request.conversationID = conversationID
        request.messageID = messageID
        request.status = status

        SanchrLogger.chat.info(
            "ChatDataSource: sendReceipt \(status) for \(messageID.prefix(8))...")
        _ = try await messagingClient.sendReceipt(request)
    }

    // MARK: - Sync Messages

    /// Syncs messages from the server since a given timestamp.
    /// Returns a GRPCAsyncResponseStream of encrypted envelopes.
    func syncMessages(sinceTimestamp: Int64) -> GRPCAsyncResponseStream<
        Vync_Messaging_EncryptedEnvelope
    > {
        var request = Vync_Messaging_SyncRequest()
        request.sinceTimestamp = sinceTimestamp

        SanchrLogger.chat.info("ChatDataSource: syncMessages since \(sinceTimestamp)")
        return messagingClient.syncMessages(request)
    }

    // MARK: - Message Stream (Bidi)

    /// Opens a bidirectional stream for real-time events (messages, typing, presence).
    func openMessageStream(
        clientEvents: AsyncStream<Vync_Messaging_ClientEvent>
    ) -> GRPCAsyncResponseStream<Vync_Messaging_ServerEvent> {
        SanchrLogger.chat.info("ChatDataSource: opening message stream")
        return messagingClient.messageStream(clientEvents)
    }

    // MARK: - Domain Model Mapping

    /// Maps a proto Conversation to the domain Conversation model.
    /// When a `contactsLookup` dictionary is provided, resolves participant display names
    /// and phone numbers from cached contacts instead of showing raw UUIDs.
    static func mapToDomainConversation(
        _ proto: Vync_Messaging_Conversation,
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
