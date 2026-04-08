import Foundation
import GRPC
import SanchrShared

/// Protocol defining messaging operations.
protocol MessageRepositoryProtocol: AnyObject, Sendable {
    /// Sends an encrypted message to a conversation.
    func sendMessage(_ message: Message) async throws -> Message

    /// Wipes a view-once message after the receiver dismissed the
    /// gallery. Deletes the local file via MediaDownloadManager,
    /// removes the DB row, and inserts a `.system(.viewOnceConsumed)`
    /// tombstone with the same id+timestamp so the bubble shows as
    /// "Viewed". Best-effort server delete is fire-and-forget.
    func deleteViewOnceMessage(messageId: String) async throws

    /// Sends a system event message into a conversation via the
    /// existing encrypted send pipeline. Used by the gallery to
    /// post `.screenshotDetected` back to the original sender when
    /// a screenshot slips through ScreenshotProtectionModifier.
    func sendSystemEvent(_ event: Message.SystemEvent, conversationId: String) async throws

    /// Fetches messages for a conversation with pagination.
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message]

    /// Fetches all conversations for the current user.
    func fetchConversations() async throws -> [Conversation]

    /// Marks messages as read up to the given message ID.
    func markAsRead(conversationId: String, upToMessageId: String) async throws

    /// Marks messages as read locally only — no read receipt sent to the server.
    func markAsReadLocally(conversationId: String, upToMessageId: String) async throws

    /// Deletes a message (local and optionally remote).
    func deleteMessage(id: String, forEveryone: Bool) async throws

    /// Opens a bidirectional message stream for real-time delivery.
    func openMessageStream() async throws -> AsyncStream<RealtimeEvent>

    /// Closes the shared bidirectional message stream.
    func closeMessageStream() async

    /// Sends a typing indicator to a conversation.
    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws

    /// Sends a device presence heartbeat through the live realtime stream.
    func sendPresenceHeartbeat(
        deviceState: Vync_Messaging_DevicePresenceState,
        sentAtMs: Int64
    ) async throws

    /// Fetches the pre-key bundle for a user to establish an encrypted session.
    func fetchPreKeyBundle(userId: String) async throws -> Data

    /// Fetches current presence state for authorized peers.
    func fetchPresenceSnapshot(userIds: [String]) async throws -> [Vync_Messaging_PresenceUpdate]

    /// Drains pending messages from the server, decrypts, and saves locally.
    func syncPendingMessages(sinceTimestamp: Int64) async throws -> MessageSyncResult

    /// Flushes locally persisted message delivery acks to the server.
    func flushPendingAcks() async throws -> Int

    /// Creates (or fetches existing) 1:1 conversation with `peerUserId`.
    /// Returns the server-assigned conversation id so the caller can
    /// deep-link into it via `AppRouter`.
    func startDirectConversation(peerUserId: String) async throws -> String
}

struct MessageSyncResult: Sendable {
    let appliedCount: Int
    let latestTimestamp: Int64
}

private actor MessageStreamController {
    private var continuation: AsyncStream<Vync_Messaging_ClientEvent>.Continuation?
    private var pendingEvents: [Vync_Messaging_ClientEvent] = []

    func begin() -> AsyncStream<Vync_Messaging_ClientEvent> {
        continuation?.finish()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
    }

    func send(_ event: Vync_Messaging_ClientEvent) {
        if let continuation {
            continuation.yield(event)
        } else {
            pendingEvents.append(event)
        }
    }

    func finish() {
        continuation?.finish()
        continuation = nil
        pendingEvents.removeAll(keepingCapacity: false)
    }

    private func setContinuation(_ continuation: AsyncStream<Vync_Messaging_ClientEvent>.Continuation) {
        self.continuation = continuation
        pendingEvents.forEach { continuation.yield($0) }
        pendingEvents.removeAll(keepingCapacity: false)
    }
}

// MARK: - Implementation

final class MessageRepositoryImpl: MessageRepositoryProtocol, @unchecked Sendable {
    private static let ackBatchSize = 100

    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let signalProtocol: SignalProtocolManagerProtocol
    private let chatVaultPolicyMirror: ChatVaultPolicyMirror
    private let vaultRepository: VaultRepositoryProtocol
    private let mediaDownloadManager: MediaDownloadManager
    private let currentUserIdProvider: @Sendable () -> String?
    private let streamController = MessageStreamController()

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        signalProtocol: SignalProtocolManagerProtocol,
        chatVaultPolicyMirror: ChatVaultPolicyMirror,
        vaultRepository: VaultRepositoryProtocol,
        mediaDownloadManager: MediaDownloadManager,
        currentUserIdProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.signalProtocol = signalProtocol
        self.chatVaultPolicyMirror = chatVaultPolicyMirror
        self.vaultRepository = vaultRepository
        self.mediaDownloadManager = mediaDownloadManager
        self.currentUserIdProvider = currentUserIdProvider
    }

    /// Returns true if the message content is something we route into
    /// the vault when the per-chat `autoVaultIncoming` policy is on.
    /// Text and system events stay as normal chat rows.
    static func isVaultEligibleContent(_ content: Message.MessageContent) -> Bool {
        switch content {
        case .image, .video, .audio, .document: return true
        case .text, .location, .contact, .system: return false
        }
    }

    static func attachmentFromContent(_ content: Message.MessageContent) -> Message.MediaAttachment? {
        switch content {
        case .image(let a), .video(let a), .audio(let a), .document(let a):
            return a
        default:
            return nil
        }
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

        // 2. Encrypt for all recipient devices via Signal Protocol.
        //
        // `encryptForAllDevices` expects the *peer user id*, never a
        // conversation id. Resolve the participants from the local DB and
        // fan out across every non-self peer.
        let senderId = currentUserIdProvider() ?? message.senderId
        guard let conversation = try await localDatabase.fetchConversation(id: message.conversationId) else {
            throw AppError.sessionNotEstablished
        }
        let peerIds = conversation.participants
            .map(\.id)
            .filter { $0 != senderId }
        guard !peerIds.isEmpty else {
            throw AppError.sessionNotEstablished
        }
        var deviceMessages: [Vync_Messaging_DeviceMessage] = []
        for peerId in peerIds {
            let perPeer = try await signalProtocol.encryptForAllDevices(
                plaintext: plaintext,
                recipientId: peerId
            )
            deviceMessages.append(contentsOf: perPeer)
        }

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
        await MainActor.run {
            NotificationCenter.default.postConversationStateDidChange(
                conversationId: message.conversationId
            )
        }

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
            let currentUserId = self.currentUserIdProvider()

            let conversations = response.conversations.map { conv -> Conversation in
                let convType: Conversation.ConversationType = conv.type == "group" ? .group : .oneToOne
                let cachedConversation = cachedLookup[conv.id]

                let updatedAt = cachedConversation?.updatedAt
                    ?? cachedConversation?.lastMessage?.timestamp
                    ?? .distantPast
                let createdAt = cachedConversation?.createdAt ?? updatedAt

                return Conversation(
                    id: conv.id,
                    participants: ChatDataSource.mapToDomainConversation(
                        conv,
                        localUserId: currentUserId
                    ).participants,
                    lastMessage: nil,
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

            return try await normalizedLocalConversations(currentUserId: currentUserId)
        } catch {
            SanchrLogger.chat.warning(
                "Fetching conversations from server failed, using local cache: \(error.localizedDescription)"
            )
            return try await normalizedLocalConversations(currentUserId: currentUserIdProvider())
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

    func markAsReadLocally(conversationId: String, upToMessageId: String) async throws {
        try await localDatabase.markConversationAsRead(
            conversationId: conversationId,
            upToMessageId: upToMessageId
        )
        SanchrLogger.chat.info("Marked conversation \(conversationId.prefix(8)) as read locally (no receipt sent)")
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

    func deleteViewOnceMessage(messageId: String) async throws {
        guard let message = try await localDatabase.fetchMessageById(messageId) else {
            SanchrLogger.chat.warning("deleteViewOnceMessage: no row for \(messageId.prefix(8))")
            return
        }
        // Wipe the cached decrypted file (if any) before deleting the
        // row so the bytes are gone before the bubble flips to the
        // tombstone state.
        await mediaDownloadManager.removeCachedFile(messageId: messageId)

        // Delete the local DB row.
        try? await localDatabase.deleteMessage(id: messageId)

        // Insert a tombstone with the same id + timestamp so the
        // bubble shows as "Viewed" instead of vanishing entirely.
        let tombstone = Message(
            id: messageId,
            conversationId: message.conversationId,
            senderId: message.senderId,
            timestamp: message.timestamp,
            content: .system(.viewOnceConsumed),
            status: .delivered,
            isOutgoing: message.isOutgoing
        )
        try? await localDatabase.saveIncomingMessageAndQueueAck(tombstone)

        // Best-effort server delete (fire-and-forget). Local file is
        // already gone so failure here is non-fatal.
        var request = Vync_Messaging_DeleteMessageRequest()
        request.messageID = messageId
        request.conversationID = message.conversationId
        _ = try? await grpcClient.messagingService.deleteMessage(request)

        SanchrLogger.chat.info("Deleted view-once message \(messageId.prefix(8))")
    }

    func sendSystemEvent(_ event: Message.SystemEvent, conversationId: String) async throws {
        SanchrLogger.chat.info("Sending system event \(event.rawValue) to \(conversationId.prefix(8))")
        let plaintext = try JSONEncoder().encode(Message.MessageContent.system(event))

        let senderId = currentUserIdProvider() ?? ""
        guard let conversation = try await localDatabase.fetchConversation(id: conversationId) else {
            throw AppError.sessionNotEstablished
        }
        let peerIds = conversation.participants
            .map(\.id)
            .filter { $0 != senderId }
        guard !peerIds.isEmpty else { return }

        var deviceMessages: [Vync_Messaging_DeviceMessage] = []
        for peerId in peerIds {
            let perPeer = try await signalProtocol.encryptForAllDevices(
                plaintext: plaintext,
                recipientId: peerId
            )
            deviceMessages.append(contentsOf: perPeer)
        }

        var request = Vync_Messaging_SendMessageRequest()
        request.conversationID = conversationId
        request.deviceMessages = deviceMessages
        request.contentType = "system"
        _ = try await grpcClient.messagingService.sendMessage(request)
    }

    func openMessageStream() async throws -> AsyncStream<RealtimeEvent> {
        SanchrLogger.chat.info("Opening bidirectional message stream")

        let requestStream = await streamController.begin()
        let responseStream = grpcClient.messagingService.messageStream(requestStream)

        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await serverEvent in responseStream {
                        guard let event = serverEvent.event else { continue }

                        switch event {
                        case .message(let envelope):
                            if let message = await self.decodeMessage(from: envelope) {
                                _ = try? await self.flushPendingAcks()
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
                        case .reaction(let reaction):
                            continuation.yield(.reaction(reaction))
                        }
                    }
                    continuation.finish()
                } catch {
                    SanchrLogger.chat.error("Message stream error: \(error)")
                    continuation.finish()
                }
                await self.streamController.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await self.streamController.finish()
                }
                SanchrLogger.chat.info("Message stream terminated")
            }
        }
    }

    func closeMessageStream() async {
        await streamController.finish()
    }

    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws {
        SanchrLogger.chat.info("Sending typing indicator: \(isTyping) for \(conversationId)")

        var typingIndicator = Vync_Messaging_TypingIndicator()
        typingIndicator.conversationID = conversationId
        typingIndicator.userID = currentUserIdProvider() ?? ""
        typingIndicator.isTyping = isTyping

        var clientEvent = Vync_Messaging_ClientEvent()
        clientEvent.typing = typingIndicator
        await streamController.send(clientEvent)
    }

    func sendPresenceHeartbeat(
        deviceState: Vync_Messaging_DevicePresenceState,
        sentAtMs: Int64
    ) async throws {
        var heartbeat = Vync_Messaging_PresenceHeartbeat()
        heartbeat.deviceState = deviceState
        heartbeat.sentAtMs = sentAtMs

        var clientEvent = Vync_Messaging_ClientEvent()
        clientEvent.heartbeat = heartbeat
        await streamController.send(clientEvent)
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

    func fetchPresenceSnapshot(userIds: [String]) async throws -> [Vync_Messaging_PresenceUpdate] {
        guard !userIds.isEmpty else { return [] }

        var request = Vync_Messaging_GetPresenceSnapshotRequest()
        request.userIds = userIds

        let response = try await grpcClient.messagingService.getPresenceSnapshot(request)
        return response.users
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

    func startDirectConversation(peerUserId: String) async throws -> String {
        var request = Vync_Messaging_StartDirectConversationRequest()
        request.recipientID = peerUserId
        let response = try await grpcClient.messagingService.startDirectConversation(request)
        SanchrLogger.chat.info(
            "startDirectConversation: peer=\(peerUserId.prefix(8)) convId=\(response.id.prefix(8))")
        return response.id
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

    private static func detailedError(_ error: Error) -> String {
        if let status = error as? GRPCStatus {
            return "gRPC \(status.code) (\(status.code.rawValue)): \(status.message ?? "no message")"
        }
        let nsError = error as NSError
        if nsError.domain == "io.grpc",
           let statusCode = GRPCStatus.Code(rawValue: nsError.code) {
            return "gRPC \(statusCode) (\(nsError.code)): \(nsError.localizedDescription)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
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

            try? await ensureConversationShellExists(
                conversationId: envelope.conversationID,
                senderId: envelope.senderID,
                serverTimestamp: serverTimestamp
            )
            try? await localDatabase.saveIncomingMessageAndQueueAck(message)

            // If per-chat policy says auto-vault, kick off a background
            // routing task. Routing runs OFF the decode hot path so we
            // never block the realtime stream on a vault upload. The
            // task succeeds → replaces the row with a `.system(.autoVaulted)`
            // tombstone. Fails → leaves the original row in place.
            let policy = chatVaultPolicyMirror.policy(for: envelope.conversationID)
                ?? .defaults(for: envelope.conversationID)
            if policy.autoVaultIncoming, Self.isVaultEligibleContent(content) {
                Task { [weak self] in
                    await self?.routeIncomingMessageToVault(message)
                }
            }

            return message
        } catch {
            SanchrLogger.chat.error("Failed to decrypt message: \(error)")
            return nil
        }
    }

    /// Background auto-vault routing. Downloads the encrypted media,
    /// uploads to the vault via the existing repository, and on success
    /// replaces the original chat row with a `.system(.autoVaulted)`
    /// tombstone. On failure leaves the original row in place so the
    /// user doesn't lose the media entirely.
    private func routeIncomingMessageToVault(_ message: Message) async {
        guard let attachment = Self.attachmentFromContent(message.content) else { return }
        do {
            let localFile = try await mediaDownloadManager.download(
                messageId: message.id,
                attachment: attachment
            )
            let data = try Data(contentsOf: localFile)
            let vaultType: VaultItem.VaultItemType = {
                switch message.content {
                case .image: return .photo
                case .video: return .video
                case .audio: return .audio
                case .document: return .document
                default: return .document
                }
            }()
            _ = try await vaultRepository.uploadItem(
                data: data,
                name: attachment.filename ?? "vaulted-\(message.id).bin",
                type: vaultType
            )

            // Replace the original chat row with a tombstone.
            let tombstone = Message(
                id: message.id,
                conversationId: message.conversationId,
                senderId: message.senderId,
                timestamp: message.timestamp,
                content: .system(.autoVaulted),
                status: .delivered,
                isOutgoing: false
            )
            try? await localDatabase.deleteMessage(id: message.id)
            try? await localDatabase.saveIncomingMessageAndQueueAck(tombstone)
            SanchrLogger.chat.info("Auto-vaulted message \(message.id.prefix(8))")
        } catch {
            SanchrLogger.chat.error(
                "Auto-vault routing failed for \(message.id.prefix(8)): \(error.localizedDescription) — leaving original row"
            )
        }
    }

    private func ensureConversationShellExists(
        conversationId: String,
        senderId: String,
        serverTimestamp: Date
    ) async throws {
        if try await localDatabase.fetchConversation(id: conversationId) != nil {
            return
        }

        SanchrLogger.chat.info(
            "Conversation \(conversationId.prefix(8)) missing locally, hydrating shell before saving incoming message"
        )

        if let remoteConversation = try? await fetchRemoteConversation(id: conversationId) {
            try await localDatabase.saveConversation(remoteConversation)
            return
        }

        let localUserId = currentUserIdProvider()
        var participants: [User] = []

        if let localUserId {
            participants.append(
                User(
                    id: localUserId,
                    phoneNumber: "",
                    displayName: "You",
                    avatarURL: nil,
                    bio: nil,
                    isVerified: true,
                    lastSeen: nil,
                    identityKeyFingerprint: nil,
                    status: .online,
                    isLocalUser: true
                )
            )
        }

        participants.append(
            User(
                id: senderId,
                phoneNumber: "",
                displayName: senderId,
                avatarURL: nil,
                bio: nil,
                isVerified: false,
                lastSeen: nil,
                identityKeyFingerprint: nil,
                status: .offline,
                isLocalUser: false
            )
        )

        let placeholderConversation = Conversation(
            id: conversationId,
            participants: participants,
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            isArchived: false,
            type: .oneToOne,
            disappearingMessagesDuration: nil,
            createdAt: serverTimestamp,
            updatedAt: serverTimestamp
        )

        try await localDatabase.saveConversation(placeholderConversation)
        SanchrLogger.chat.warning(
            "Saved placeholder conversation shell for \(conversationId.prefix(8)) because server hydration was unavailable"
        )
    }

    private func fetchRemoteConversation(id conversationId: String) async throws -> Conversation? {
        let request = Vync_Messaging_GetConversationsRequest()
        let response = try await grpcClient.messagingService.getConversations(request)
        guard let protoConversation = response.conversations.first(where: { $0.id == conversationId }) else {
            return nil
        }

        let contacts = (try? await localDatabase.fetchContacts()) ?? []
        let contactsLookup = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        return ChatDataSource.mapToDomainConversation(
            protoConversation,
            contactsLookup: contactsLookup,
            localUserId: currentUserIdProvider()
        )
    }

    private func normalizedLocalConversations(currentUserId: String?) async throws -> [Conversation] {
        let contacts = (try? await localDatabase.fetchContacts()) ?? []
        let contactsLookup = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        return try await localDatabase.fetchConversations().map { conversation in
            var normalizedConversation = conversation
            normalizedConversation.participants = conversation.participants.map { participant in
                var normalizedParticipant = participant
                let isLocal = participant.id == currentUserId
                normalizedParticipant.isLocalUser = isLocal
                if !isLocal, let contact = contactsLookup[participant.id] {
                    if normalizedParticipant.displayName.isEmpty || normalizedParticipant.displayName == participant.id {
                        normalizedParticipant.displayName = contact.displayName
                    }
                    if normalizedParticipant.avatarURL == nil {
                        normalizedParticipant.avatarURL = contact.avatarURL
                    }
                }
                return normalizedParticipant
            }
            return normalizedConversation
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
