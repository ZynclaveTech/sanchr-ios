import Foundation
import GRPC

/// Protocol defining messaging operations.
protocol MessageRepositoryProtocol: AnyObject, Sendable {
    /// Sends an encrypted message to a conversation.
    func sendMessage(_ message: Message) async throws -> Message

    /// Fetches messages for a conversation with pagination.
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message]

    /// Fetches all conversations for the current user.
    func fetchConversations() async throws -> [Conversation]

    /// Marks messages as read up to the given message ID.
    func markAsRead(conversationId: String, upToMessageId: String) async throws

    /// Deletes a message (local and optionally remote).
    func deleteMessage(id: String, forEveryone: Bool) async throws

    /// Opens a bidirectional message stream for real-time delivery.
    func openMessageStream() async throws -> AsyncStream<RealtimeEvent>

    /// Sends a typing indicator to a conversation.
    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws

    /// Fetches the pre-key bundle for a user to establish an encrypted session.
    func fetchPreKeyBundle(userId: String) async throws -> Data

    /// Drains pending messages from the server, decrypts, and saves locally.
    func syncPendingMessages(sinceTimestamp: Int64) async throws -> MessageSyncResult

    /// Flushes locally persisted message delivery acks to the server.
    func flushPendingAcks() async throws -> Int
}

struct MessageSyncResult: Sendable {
    let appliedCount: Int
    let latestTimestamp: Int64
}

// MARK: - Implementation

final class MessageRepositoryImpl: MessageRepositoryProtocol, @unchecked Sendable {
    private static let ackBatchSize = 100

    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let signalProtocol: SignalProtocolManagerProtocol

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        signalProtocol: SignalProtocolManagerProtocol
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.signalProtocol = signalProtocol
    }

    func sendMessage(_ message: Message) async throws -> Message {
        SanchrLogger.chat.info("Sending message \(message.id) to conversation \(message.conversationId)")

        // 1. Serialize message content to plaintext bytes
        let plaintext: Data
        switch message.content {
        case .text(let text):
            plaintext = Data(text.utf8)
        default:
            // For non-text content, JSON-encode the content
            let encoder = JSONEncoder()
            plaintext = try encoder.encode(message.content)
        }

        // 2. Encrypt for all recipient devices via Signal Protocol
        // The recipientId is derived from the conversation participants.
        // For 1:1, the senderId is the local user, so we encrypt for the other participant.
        // The signalProtocol.encryptForAllDevices handles fetching device list and per-device encryption.
        let deviceMessages = try await signalProtocol.encryptForAllDevices(
            plaintext: plaintext,
            recipientId: message.conversationId
        )

        // 3. Send encrypted message via gRPC
        var request = Vync_Messaging_SendMessageRequest()
        request.conversationID = message.conversationId
        request.deviceMessages = deviceMessages
        request.contentType = Self.contentTypeString(for: message.content)
        if let expiresAt = message.expiresAt {
            request.expiresAfterSecs = Int64(expiresAt.timeIntervalSinceNow)
        }

        let response = try await grpcClient.messagingService.sendMessage(request)

        // 4. Update message with server-assigned ID and timestamp, save locally
        let serverTimestamp = Date(timeIntervalSince1970: TimeInterval(response.serverTimestamp) / 1000.0)
        var sentMessage = message
        sentMessage.status = .sent

        let updatedMessage = Message(
            id: response.messageID.isEmpty ? message.id : response.messageID,
            conversationId: message.conversationId,
            senderId: message.senderId,
            timestamp: serverTimestamp,
            content: message.content,
            status: .sent,
            isOutgoing: message.isOutgoing,
            replyToMessageId: message.replyToMessageId,
            expiresAt: message.expiresAt
        )

        try await localDatabase.saveMessage(updatedMessage)

        SanchrLogger.chat.info("Message sent successfully: \(updatedMessage.id)")
        return updatedMessage
    }

    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] {
        return try await localDatabase.fetchMessages(
            conversationId: conversationId,
            before: before,
            limit: limit
        )
    }

    func fetchConversations() async throws -> [Conversation] {
        SanchrLogger.chat.info("Fetching conversations from server")
        do {
            let request = Vync_Messaging_GetConversationsRequest()
            let response = try await grpcClient.messagingService.getConversations(request)
            let cachedConversations = (try? await localDatabase.fetchConversations()) ?? []
            let cachedLookup = Dictionary(uniqueKeysWithValues: cachedConversations.map { ($0.id, $0) })

            // Build a contacts lookup to resolve participant names
            let contacts = (try? await localDatabase.fetchContacts()) ?? []
            let contactsLookup = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })

            let conversations = response.conversations.map { conv -> Conversation in
                let convType: Conversation.ConversationType = conv.type == "group" ? .group : .oneToOne
                let cachedConversation = cachedLookup[conv.id]

                let participants = conv.participantIds.map { participantId -> User in
                    if let cached = contactsLookup[participantId] {
                        return cached
                    }
                    return User(
                        id: participantId,
                        phoneNumber: "",
                        displayName: participantId,
                        avatarURL: nil,
                        bio: nil,
                        isVerified: false,
                        lastSeen: nil,
                        identityKeyFingerprint: nil,
                        status: .offline
                    )
                }

                let updatedAt = cachedConversation?.updatedAt
                    ?? cachedConversation?.lastMessage?.timestamp
                    ?? .distantPast
                let createdAt = cachedConversation?.createdAt ?? updatedAt

                return Conversation(
                    id: conv.id,
                    participants: participants,
                    lastMessage: cachedConversation?.lastMessage,
                    unreadCount: Int(conv.unreadCount),
                    isPinned: cachedConversation?.isPinned ?? false,
                    isMuted: cachedConversation?.isMuted ?? false,
                    isArchived: cachedConversation?.isArchived ?? false,
                    type: convType,
                    disappearingMessagesDuration: cachedConversation?.disappearingMessagesDuration,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            }

            for conversation in conversations {
                try? await localDatabase.saveConversation(conversation)
            }

            return conversations
        } catch {
            SanchrLogger.chat.warning(
                "Fetching conversations from server failed, using local cache: \(error.localizedDescription)"
            )
            return try await localDatabase.fetchConversations()
        }
    }

    func markAsRead(conversationId: String, upToMessageId: String) async throws {
        SanchrLogger.chat.info("Marking messages as read in \(conversationId) up to \(upToMessageId)")

        var request = Vync_Messaging_ReceiptRequest()
        request.conversationID = conversationId
        request.messageID = upToMessageId
        request.status = "read"

        _ = try await grpcClient.messagingService.sendReceipt(request)

        try await localDatabase.markConversationAsRead(
            conversationId: conversationId,
            upToMessageId: upToMessageId
        )
    }

    func deleteMessage(id: String, forEveryone: Bool) async throws {
        SanchrLogger.chat.info("Deleting message \(id), forEveryone: \(forEveryone)")

        if forEveryone {
            var request = Vync_Messaging_DeleteMessageRequest()
            request.messageID = id

            _ = try await grpcClient.messagingService.deleteMessage(request)
        }

        // Always delete locally
        try await localDatabase.deleteMessage(id: id)
    }

    func openMessageStream() async throws -> AsyncStream<RealtimeEvent> {
        SanchrLogger.chat.info("Opening bidirectional message stream")

        // Use the async bidirectional stream API.
        // We send an initial empty sequence and listen for server events.
        let emptyRequests: [Vync_Messaging_ClientEvent] = []
        let responseStream = grpcClient.messagingService.messageStream(emptyRequests)

        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await serverEvent in responseStream {
                        guard let event = serverEvent.event else { continue }

                        switch event {
                        case .message(let envelope):
                            if let message = await self.decodeMessage(from: envelope) {
                                try? await self.flushPendingAcks()
                                continuation.yield(.message(message))
                            }
                        case .typing(let indicator):
                            continuation.yield(.typing(indicator))
                        case .receipt(let receipt):
                            if let status = Message.DeliveryStatus(rawValue: receipt.status) {
                                try? await self.localDatabase.updateMessageStatus(
                                    id: receipt.messageID,
                                    status: status
                                )
                            }
                            continuation.yield(.receipt(receipt))
                        case .presence(let presence):
                            continuation.yield(.presence(presence))
                        case .preKeyCountLow(let preKeyCountLow):
                            continuation.yield(.preKeyCountLow(preKeyCountLow))
                        case .callOffer(let offer):
                            continuation.yield(.callOffer(offer))
                        case .callLifecycle(let lifecycle):
                            continuation.yield(.callLifecycle(lifecycle))
                        }
                    }
                    continuation.finish()
                } catch {
                    SanchrLogger.chat.error("Message stream error: \(error)")
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                SanchrLogger.chat.info("Message stream terminated")
            }
        }
    }

    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws {
        SanchrLogger.chat.info("Sending typing indicator: \(isTyping) for \(conversationId)")

        // Send typing indicator via the message stream as a client event.
        // Since we use unary-style for simplicity (the stream may not be open),
        // we create a fresh short-lived bidi call to send the typing event.
        var typingIndicator = Vync_Messaging_TypingIndicator()
        typingIndicator.conversationID = conversationId
        typingIndicator.isTyping = isTyping

        var clientEvent = Vync_Messaging_ClientEvent()
        clientEvent.typing = typingIndicator

        // Send as a single-element sequence
        let requests = [clientEvent]
        _ = grpcClient.messagingService.messageStream(requests)
    }

    func fetchPreKeyBundle(userId: String) async throws -> Data {
        SanchrLogger.crypto.info("Fetching pre-key bundle for \(userId.prefix(8))...")

        var request = Vync_Keys_GetPreKeyBundleRequest()
        request.userID = userId
        request.deviceID = 1 // Default device

        let response = try await grpcClient.keyService.getPreKeyBundle(request)

        // Serialize the pre-key bundle response to Data for the caller
        return try response.serializedData()
    }

    // MARK: - Sync

    func syncPendingMessages(sinceTimestamp: Int64) async throws -> MessageSyncResult {
        SanchrLogger.chat.info("Syncing pending messages from server")

        var request = Vync_Messaging_SyncRequest()
        request.sinceTimestamp = sinceTimestamp

        let stream = grpcClient.messagingService.syncMessages(request)
        var count = 0
        var latestTimestamp = sinceTimestamp

        for try await envelope in stream {
            if let message = await decodeMessage(from: envelope) {
                count += 1
                latestTimestamp = max(latestTimestamp, Int64(message.timestamp.timeIntervalSince1970 * 1000))
            }
        }

        _ = try await flushPendingAcks()

        if count > 0 {
            SanchrLogger.chat.info("Synced \(count) pending message(s) from server")
        }

        return MessageSyncResult(appliedCount: count, latestTimestamp: latestTimestamp)
    }

    func flushPendingAcks() async throws -> Int {
        let pendingAcks = try await localDatabase.fetchPendingMessageAcks(limit: Self.ackBatchSize)
        guard !pendingAcks.isEmpty else { return 0 }

        var request = Vync_Messaging_AckMessagesRequest()
        request.messages = pendingAcks.map { ack in
            var ref = Vync_Messaging_AckedMessageRef()
            ref.conversationID = ack.conversationId
            ref.messageID = ack.messageId
            return ref
        }

        _ = try await grpcClient.messagingService.ackMessages(request)
        try await localDatabase.deletePendingMessageAcks(pendingAcks)

        SanchrLogger.chat.info("Flushed \(pendingAcks.count) pending delivery ack(s)")
        return pendingAcks.count
    }

    // MARK: - Helpers

    private static func contentTypeString(for content: Message.MessageContent) -> String {
        switch content {
        case .text: return "text"
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .document: return "document"
        case .location: return "location"
        case .contact: return "contact"
        case .system: return "system"
        }
    }

    private func decodeMessage(from envelope: Vync_Messaging_EncryptedEnvelope) async -> Message? {
        do {
            let plaintext = try await signalProtocol.decryptEnvelope(envelope)
            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(envelope.serverTimestamp) / 1000.0
            )

            let content = decodeContent(
                plaintext,
                contentType: envelope.contentType
            )

            let message = Message(
                id: envelope.messageID,
                conversationId: envelope.conversationID,
                senderId: envelope.senderID,
                timestamp: serverTimestamp,
                content: content,
                status: .delivered,
                isOutgoing: false
            )

            try? await localDatabase.saveIncomingMessageAndQueueAck(message)
            return message
        } catch {
            SanchrLogger.chat.error("Failed to decrypt message: \(error)")
            return nil
        }
    }

    private func decodeContent(_ plaintext: Data, contentType: String) -> Message.MessageContent {
        switch contentType {
        case "text":
            return .text(String(data: plaintext, encoding: .utf8) ?? "")
        default:
            if let content = try? JSONDecoder().decode(Message.MessageContent.self, from: plaintext) {
                return content
            }
            return .text(String(data: plaintext, encoding: .utf8) ?? "")
        }
    }
}
