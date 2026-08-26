import Foundation
import GRPC
import UIKit
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
    /// Local, no-network conversation load that still joins contacts, so a
    /// cached refresh shows resolved names instead of the raw placeholder.
    func fetchCachedConversations() async throws -> [Conversation]

    /// Persists local-only conversation presentation flags.
    func setConversationPinned(conversationId: String, isPinned: Bool) async throws
    func setConversationMuted(conversationId: String, isMuted: Bool) async throws
    func setConversationArchived(conversationId: String, isArchived: Bool) async throws
    func hideConversationLocally(conversationId: String) async throws
    func restoreConversationLocally(conversationId: String) async throws

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

    /// Acknowledges that a queued call event was handled and can be removed server-side.
    func ackCallEvent(callId: String, kind: String) async

    /// Sends a typing indicator to a conversation.
    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws

    /// Sends a P2P sealed-sender presence update directly to a contact's devices.
    /// Presence rides inside a sealed envelope (contentType "presence/v1") so the
    /// server cannot read it or correlate it with user identity.
    func sendP2PPresence(
        recipientUserId: String,
        statusCode: Sanchr_Messaging_PresenceStatus,
        lastSeenMs: Int64
    ) async throws

    /// Fetches the pre-key bundle for a user to establish an encrypted session.
    func fetchPreKeyBundle(userId: String) async throws -> Data

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
    let appliedCountsByConversation: [String: Int]
}

private enum SealedDecodeOutcome {
    case event(RealtimeEvent)
    case undeliverable(Error)
}

actor MessageStreamController {
    private let bufferLimit = 64
    private var continuation: AsyncStream<Sanchr_Messaging_ClientEvent>.Continuation?
    private var bufferedEvents: [Sanchr_Messaging_ClientEvent] = []

    func begin() -> AsyncStream<Sanchr_Messaging_ClientEvent> {
        continuation?.finish()
        continuation = nil
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
    }

    func send(_ event: Sanchr_Messaging_ClientEvent) {
        if let continuation {
            continuation.yield(event)
            return
        }

        bufferedEvents.append(event)
        if bufferedEvents.count > bufferLimit {
            bufferedEvents.removeFirst(bufferedEvents.count - bufferLimit)
        }
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }

    private func setContinuation(_ continuation: AsyncStream<Sanchr_Messaging_ClientEvent>.Continuation) {
        self.continuation = continuation
        guard !bufferedEvents.isEmpty else { return }

        let events = bufferedEvents
        bufferedEvents.removeAll(keepingCapacity: true)
        for event in events {
            continuation.yield(event)
        }
    }
}

actor MessageEnvelopeReplayGate {
    private let limit: Int
    private var inFlight: Set<String> = []
    private var recent: [String] = []
    private var recentSet: Set<String> = []

    init(limit: Int = 512) {
        self.limit = max(1, limit)
    }

    func begin(_ messageId: String) -> Bool {
        let key = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return true }
        guard !inFlight.contains(key), !recentSet.contains(key) else { return false }

        inFlight.insert(key)
        return true
    }

    func finish(_ messageId: String, remember: Bool) {
        let key = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        inFlight.remove(key)
        guard remember, !recentSet.contains(key) else { return }

        recent.append(key)
        recentSet.insert(key)

        while recent.count > limit {
            let removed = recent.removeFirst()
            recentSet.remove(removed)
        }
    }
}

/// Gates profile-name resolution so it runs until it succeeds, then stops.
///
/// Resolution used to run only when a peer's Profile Key was *new*. But if an
/// earlier attempt stored the key without resolving the name — a failed fetch, a
/// decrypt miss, a stale build — every later message saw the key as "not new"
/// and skipped resolution forever, so the name never appeared. This retries on
/// each message while a peer is unresolved, coalesces concurrent attempts, and
/// stops once resolved.
private actor ProfileResolutionCoordinator {
    private var resolved: Set<String> = []
    private var inFlight: Set<String> = []

    /// Returns true (and marks in-flight) if a resolution should start for `id`.
    func begin(_ id: String) -> Bool {
        guard !resolved.contains(id), !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    func succeed(_ id: String) {
        inFlight.remove(id)
        resolved.insert(id)
    }

    /// Allow a later message to retry.
    func fail(_ id: String) {
        inFlight.remove(id)
    }

    /// A changed key means the peer may have a new name; clear the resolved mark.
    func invalidate(_ id: String) {
        resolved.remove(id)
    }
}

private actor SealedDropLogLimiter {
    private let interval: Int
    private var droppedCount = 0

    init(interval: Int = 50) {
        self.interval = max(1, interval)
    }

    func recordDrop() -> Int? {
        droppedCount += 1
        if droppedCount == 1 || droppedCount % interval == 0 {
            return droppedCount
        }
        return nil
    }
}

// MARK: - Implementation

final class MessageRepositoryImpl: MessageRepositoryProtocol, @unchecked Sendable {
    private static let ackBatchSize = 100
    private static let nilUUIDString = "00000000-0000-0000-0000-000000000000"

    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let signalProtocol: SignalProtocolManagerProtocol
    private let sealedSenderManager: SealedSenderManagerProtocol
    private let chatVaultPolicyMirror: ChatVaultPolicyMirror
    private let vaultRepository: VaultRepositoryProtocol
    private let mediaDownloadManager: MediaDownloadManager
    private let currentUserIdProvider: @Sendable () -> String?
    private let streamController = MessageStreamController()
    private let sealedEnvelopeReplayGate = MessageEnvelopeReplayGate()
    private let profileResolutionCoordinator = ProfileResolutionCoordinator()
    private let sealedDropLogLimiter = SealedDropLogLimiter()
    private let privacyGate: MessagingPrivacyGate
    private let receiptDelayNanoseconds: @Sendable () -> UInt64
    private let profileKeyStore: ProfileKeyStoreProtocol

    /// Sealed-envelope content type carrying a 32-byte Profile Key.
    static let profileKeyContentType = "profile-key/v1"
    private static let profileKeyByteCount = 32

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        signalProtocol: SignalProtocolManagerProtocol,
        sealedSenderManager: SealedSenderManagerProtocol,
        chatVaultPolicyMirror: ChatVaultPolicyMirror,
        vaultRepository: VaultRepositoryProtocol,
        mediaDownloadManager: MediaDownloadManager,
        currentUserIdProvider: @escaping @Sendable () -> String? = { nil },
        privacySettings: PrivacySettingsCache,
        profileKeyStore: ProfileKeyStoreProtocol,
        receiptDelayNanoseconds: @escaping @Sendable () -> UInt64 = {
            UInt64(Double.random(in: 0...3) * 1_000_000_000)
        }
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.signalProtocol = signalProtocol
        self.sealedSenderManager = sealedSenderManager
        self.chatVaultPolicyMirror = chatVaultPolicyMirror
        self.vaultRepository = vaultRepository
        self.mediaDownloadManager = mediaDownloadManager
        self.currentUserIdProvider = currentUserIdProvider
        self.privacyGate = MessagingPrivacyGate(privacySettings: privacySettings)
        self.receiptDelayNanoseconds = receiptDelayNanoseconds
        self.profileKeyStore = profileKeyStore
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

        // 3. Wrap plaintext in InnerPayload and encrypt via sealed sender path.
        //    The server sees only delivery_token + per-device ciphertext; sender_id is
        //    never transmitted — it stays hidden behind the delivery token.
        let contentType = Self.contentTypeString(for: message.content)
        // Read from the encrypted conversation row rather than UserDefaults.
        let disappearingSecs =
            (try? await localDatabase.disappearingDuration(
                conversationId: message.conversationId)) ?? 0

        let innerPayload = try sealedSenderManager.encodeInnerPayload(
            conversationId: message.conversationId,
            messageId: message.id,
            contentType: contentType,
            content: plaintext,
            isSync: false,
            // The disappearing timer travels inside the envelope so the recipient
            // can enforce it. SendSealedMessageRequest has no TTL field, and the
            // server should not learn the timer in any case.
            expiresAfterSecs: disappearingSecs > 0 ? disappearingSecs : nil
        )
        let deliveryToken = try await sealedSenderManager.acquireDeliveryToken()

        var sealedDeviceMessages: [Sanchr_Messaging_SealedDeviceMessage] = []
        // Encryption is all-or-nothing: if any peer's device fails, the whole send throws
        // and no device messages are delivered. This is correct Signal behavior — partial
        // device-set delivery on first send would break session consistency.
        for peerId in peerIds {
            let encrypted = try await signalProtocol.encryptForAllDevices(
                plaintext: innerPayload,
                recipientId: peerId
            )
            for dm in encrypted {
                var sdm = Sanchr_Messaging_SealedDeviceMessage()
                sdm.recipientID = dm.recipientID
                sdm.deviceID = dm.deviceID
                sdm.sealedEnvelope = dm.ciphertext
                sealedDeviceMessages.append(sdm)
            }
        }

        var request = Sanchr_Messaging_SendSealedMessageRequest()
        request.deliveryToken = deliveryToken
        request.deviceMessages = sealedDeviceMessages
        // SendSealedMessageRequest deliberately carries no TTL field: the timer
        // travels inside the sealed InnerPayload instead, so the server never
        // learns it. Expiry is enforced on each device by
        // DisappearingMessageSweeper, and fetchMessages hides anything past its
        // deadline in the window before a sweep runs.

        let response = try await grpcClient.messagingService.sendSealedMessage(request)

        // Schedule background token pool replenishment (fire-and-forget).
        Task { [sealedSenderManager] in await sealedSenderManager.replenishIfNeeded() }

        // 4. Update message with server-assigned ID and timestamp, save locally
        let serverTimestamp = Date(timeIntervalSince1970: TimeInterval(response.serverTimestamp) / 1000.0)

        // Sealed responses carry no messageID — the client-generated UUID is canonical.
        let updatedMessage = Message(
            id: message.id,
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

    func fetchCachedConversations() async throws -> [Conversation] {
        let conversations = try await normalizedLocalConversations(
            currentUserId: currentUserIdProvider())
        // Resolution is otherwise only driven by inbound envelopes, so a peer we
        // already hold a Profile Key for stays "Unknown" on a cold launch until
        // they happen to send something. Kick off a proactive pass from the
        // stored keys — the coordinator dedupes, so this is a no-op once resolved.
        Task { [weak self] in await self?.resolveStoredProfilesIfNeeded() }
        return conversations
    }

    func fetchConversations() async throws -> [Conversation] {
        SanchrLogger.chat.info("Fetching conversations from server")
        do {
            let request = Sanchr_Messaging_GetConversationsRequest()
            let response = try await grpcClient.messagingService.getConversations(request)
            let cachedConversations = (try? await localDatabase.fetchAllConversationsIncludingHidden()) ?? []
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
                    // Prefer local unread count: it's updated incrementally by
                    // saveIncomingMessageAndQueueAck (increment) and markConversationAsRead
                    // (zero). The server count lags behind because read receipts are
                    // processed asynchronously, so using it would overwrite the local
                    // mark-as-read and bring the badge back.
                    unreadCount: cachedConversation?.unreadCount ?? Int(conv.unreadCount),
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

    func setConversationPinned(conversationId: String, isPinned: Bool) async throws {
        try await updateConversation(conversationId: conversationId) { conversation in
            conversation.isPinned = isPinned
        }
    }

    func setConversationMuted(conversationId: String, isMuted: Bool) async throws {
        try await updateConversation(conversationId: conversationId) { conversation in
            conversation.isMuted = isMuted
        }
    }

    func setConversationArchived(conversationId: String, isArchived: Bool) async throws {
        try await updateConversation(conversationId: conversationId) { conversation in
            conversation.isArchived = isArchived
        }
    }

    func hideConversationLocally(conversationId: String) async throws {
        try await localDatabase.setConversationHidden(id: conversationId, isHidden: true)
        await MainActor.run {
            NotificationCenter.default.postConversationStateDidChange(conversationId: conversationId)
        }
    }

    func restoreConversationLocally(conversationId: String) async throws {
        try await localDatabase.setConversationHidden(id: conversationId, isHidden: false)
        await MainActor.run {
            NotificationCenter.default.postConversationStateDidChange(conversationId: conversationId)
        }
    }

    func markAsRead(conversationId: String, upToMessageId: String) async throws {
        switch privacyGate.decide(.readReceipt) {
        case .suppress:
            try await markAsReadLocally(
                conversationId: conversationId,
                upToMessageId: upToMessageId
            )
            SanchrLogger.chat.info(
                "markAsRead gated by privacy settings — local-only for \(conversationId.prefix(8))"
            )
            return
        case .allow:
            break
        }

        SanchrLogger.chat.info("Marking messages as read in \(conversationId) up to \(upToMessageId)")

        // Update local DB immediately so the UI reflects read state without delay.
        try await localDatabase.markConversationAsRead(
            conversationId: conversationId,
            upToMessageId: upToMessageId
        )

        guard let peerUserId = try? await oneToOneReceiptPeerId(
            conversationId: conversationId
        ) else {
            return
        }

        // Dispatch the read receipt as a sealed-sender envelope so the server
        // cannot read its contents or correlate the timestamp with our identity.
        // A random 0-30 s jitter masks exact read-timing from metadata analysis.
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.receiptDelayNanoseconds())
            await self.sendSealedReceipt(
                conversationId: conversationId,
                messageId: upToMessageId,
                peerUserId: peerUserId
            )
        }
    }

    func markAsReadLocally(conversationId: String, upToMessageId: String) async throws {
        try await localDatabase.markConversationAsRead(
            conversationId: conversationId,
            upToMessageId: upToMessageId
        )
        SanchrLogger.chat.info("Marked conversation \(conversationId.prefix(8)) as read locally (no receipt sent)")
    }

    /// Sends a read receipt as a sealed-sender envelope (contentType "receipt/v1")
    /// directly to the peer. The server routes it as opaque ciphertext and cannot
    /// read the conversation ID, message ID, or timestamp.
    private func oneToOneReceiptPeerId(conversationId: String) async throws -> String? {
        guard let myUserId = currentUserIdProvider() else { return nil }
        guard let conversation = try await localDatabase.fetchConversation(id: conversationId),
              conversation.type == .oneToOne
        else { return nil }

        return conversation.participants.first { $0.id != myUserId && !$0.id.isEmpty }?.id
    }

    private func sendSealedReceipt(
        conversationId: String,
        messageId: String,
        peerUserId: String
    ) async {
        guard let myUserId = currentUserIdProvider(), !myUserId.isEmpty else {
            SanchrLogger.chat.warning("sendSealedReceipt: missing current user id")
            return
        }

        do {
            var receiptUpdate = Sanchr_Messaging_ReceiptUpdate()
            receiptUpdate.conversationID = conversationId
            receiptUpdate.messageID = messageId
            receiptUpdate.recipientID = myUserId
            receiptUpdate.status = "read"
            receiptUpdate.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

            let content = try receiptUpdate.serializedData()
            let innerPayload = try sealedSenderManager.encodeInnerPayload(
                conversationId: "",
                messageId: nil,
                contentType: "receipt/v1",
                content: content,
                isSync: false,
                // Control payloads carry no disappearing timer.
                expiresAfterSecs: nil
            )
            let deliveryToken = try await sealedSenderManager.acquireDeliveryToken()

            let encrypted = try await signalProtocol.encryptForAllDevices(
                plaintext: innerPayload,
                recipientId: peerUserId
            )
            guard !encrypted.isEmpty else { return }

            let deviceMessages = encrypted.map { dm -> Sanchr_Messaging_SealedDeviceMessage in
                var sdm = Sanchr_Messaging_SealedDeviceMessage()
                sdm.recipientID = dm.recipientID
                sdm.deviceID = dm.deviceID
                sdm.sealedEnvelope = dm.ciphertext
                return sdm
            }

            var request = Sanchr_Messaging_SendSealedMessageRequest()
            request.deliveryToken = deliveryToken
            request.deviceMessages = deviceMessages
            _ = try await grpcClient.messagingService.sendSealedMessage(request)

            Task { [sealedSenderManager] in await sealedSenderManager.replenishIfNeeded() }
            SanchrLogger.chat.debug(
                "Sealed receipt sent to \(peerUserId.prefix(8)) for msg \(messageId.prefix(8))"
            )
        } catch {
            SanchrLogger.chat.warning("sendSealedReceipt failed: \(error.localizedDescription)")
        }
    }

    func deleteMessage(id: String, forEveryone: Bool) async throws {
        SanchrLogger.chat.info("Deleting message \(id), forEveryone: \(forEveryone)")

        if forEveryone {
            var request = Sanchr_Messaging_DeleteMessageRequest()
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
        var request = Sanchr_Messaging_DeleteMessageRequest()
        request.messageID = messageId
        request.conversationID = message.conversationId
        _ = try? await grpcClient.messagingService.deleteMessage(request)

        // Notify the chat list + detail so the bubble flips to the
        // tombstone state without requiring a nav-away/return.
        await MainActor.run {
            NotificationCenter.default.postConversationStateDidChange(
                conversationId: message.conversationId
            )
        }

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

        var deviceMessages: [Sanchr_Messaging_DeviceMessage] = []
        for peerId in peerIds {
            let perPeer = try await signalProtocol.encryptForAllDevices(
                plaintext: plaintext,
                recipientId: peerId
            )
            deviceMessages.append(contentsOf: perPeer)
        }

        var request = Sanchr_Messaging_SendMessageRequest()
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
                            if Self.shouldDecodeAsSealed(envelope) {
                                guard await self.sealedEnvelopeReplayGate.begin(envelope.messageID) else {
                                    continue
                                }

                                var shouldRememberEnvelope = false
                                switch await self.decodeSealedEnvelope(envelope) {
                                case .event(let event):
                                    shouldRememberEnvelope = await self.ackDeliveredEnvelope(
                                        messageId: envelope.messageID,
                                        conversationId: envelope.conversationID
                                    )
                                    if case .message = event {
                                        let flushedCount = (try? await self.flushPendingAcks()) ?? 0
                                        shouldRememberEnvelope = shouldRememberEnvelope || flushedCount > 0
                                    }
                                    continuation.yield(event)
                                case .undeliverable(let error):
                                    shouldRememberEnvelope = await self.ackUndeliverableSealedMessage(
                                        messageId: envelope.messageID,
                                        conversationId: envelope.conversationID,
                                        error: error
                                    )
                                }
                                await self.sealedEnvelopeReplayGate.finish(
                                    envelope.messageID,
                                    remember: shouldRememberEnvelope
                                )
                            } else if let message = await self.decodeMessage(from: envelope) {
                                _ = try? await self.flushPendingAcks()
                                continuation.yield(.message(message))
                            }
                        case .messageEdited:
                            break
                        case .typing(let indicator):
                            continuation.yield(.typing(indicator))
                        case .receipt(let receipt):
                            if let status = Message.DeliveryStatus(rawValue: receipt.status) {
                                try? await self.localDatabase.updateMessageStatus(
                                    id: receipt.messageID,
                                    status: status
                                )
                                // Keep the chat-list double-tick in
                                // sync: only patch the conversation's
                                // denormalized status if the receipt
                                // targets the CURRENT last message.
                                try? await self.localDatabase
                                    .updateConversationLastMessageStatusIfMatches(
                                        conversationId: receipt.conversationID,
                                        messageId: receipt.messageID,
                                        status: status
                                    )
                            }
                            continuation.yield(.receipt(receipt))
                        case .preKeyCountLow(let preKeyCountLow):
                            continuation.yield(.preKeyCountLow(preKeyCountLow))
                        case .callOffer(let offer):
                            continuation.yield(.callOffer(offer))
                        case .callLifecycle(let lifecycle):
                            continuation.yield(.callLifecycle(lifecycle))
                        case .reaction(let reaction):
                            continuation.yield(.reaction(reaction))
                        case .sealedMessage(let sealed):
                            guard await self.sealedEnvelopeReplayGate.begin(sealed.messageID) else {
                                continue
                            }

                            var shouldRememberEnvelope = false
                            switch await self.decodeSealedMessage(from: sealed) {
                            case .event(let event):
                                shouldRememberEnvelope = await self.ackDeliveredEnvelope(
                                    messageId: sealed.messageID,
                                    conversationId: Self.nilUUIDString
                                )
                                if case .message = event {
                                    let flushedCount = (try? await self.flushPendingAcks()) ?? 0
                                    shouldRememberEnvelope = shouldRememberEnvelope || flushedCount > 0
                                }
                                continuation.yield(event)
                            case .undeliverable(let error):
                                shouldRememberEnvelope = await self.ackUndeliverableSealedMessage(
                                    messageId: sealed.messageID,
                                    conversationId: Self.nilUUIDString,
                                    error: error
                                )
                            }
                            await self.sealedEnvelopeReplayGate.finish(
                                sealed.messageID,
                                remember: shouldRememberEnvelope
                            )
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

    func ackCallEvent(callId: String, kind: String) async {
        guard !callId.isEmpty, kind == "offer" || kind == "lifecycle" else { return }
        var ack = Sanchr_Messaging_CallEventAck()
        ack.callID = callId
        ack.kind = kind

        var clientEvent = Sanchr_Messaging_ClientEvent()
        clientEvent.callEventAck = ack
        await streamController.send(clientEvent)
    }

    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws {
        guard privacyGate.decide(.typingIndicator) == .allow else { return }

        SanchrLogger.chat.info("Sending typing indicator: \(isTyping) for \(conversationId)")

        var typingIndicator = Sanchr_Messaging_TypingIndicator()
        typingIndicator.conversationID = conversationId
        typingIndicator.userID = currentUserIdProvider() ?? ""
        typingIndicator.isTyping = isTyping

        var clientEvent = Sanchr_Messaging_ClientEvent()
        clientEvent.typing = typingIndicator
        await streamController.send(clientEvent)
    }

    func sendP2PPresence(
        recipientUserId: String,
        statusCode: Sanchr_Messaging_PresenceStatus,
        lastSeenMs: Int64
    ) async throws {
        let effectiveStatus: Sanchr_Messaging_PresenceStatus
        switch privacyGate.decidePresenceStatus(requested: statusCode) {
        case .allow(let status):
            effectiveStatus = status
        case .suppress:
            return
        }

        guard let currentUserId = currentUserIdProvider(), !currentUserId.isEmpty else {
            SanchrLogger.chat.warning("sendP2PPresence: missing current user id")
            return
        }
        guard !recipientUserId.isEmpty else { return }

        var presenceUpdate = Sanchr_Messaging_PresenceUpdate()
        presenceUpdate.userID = currentUserId
        presenceUpdate.statusCode = effectiveStatus
        presenceUpdate.status = Self.presenceStatusString(effectiveStatus)
        presenceUpdate.lastSeen = effectiveStatus == .online ? 0 : lastSeenMs

        let content = try presenceUpdate.serializedData()
        let innerPayload = try sealedSenderManager.encodeInnerPayload(
            conversationId: "",
            messageId: nil,
            contentType: "presence/v1",
            content: content,
            isSync: false,
            // Control payloads carry no disappearing timer.
            expiresAfterSecs: nil
        )
        let deliveryToken = try await sealedSenderManager.acquireDeliveryToken()

        let encrypted = try await signalProtocol.encryptForAllDevices(
            plaintext: innerPayload,
            recipientId: recipientUserId
        )
        guard !encrypted.isEmpty else { return }

        let deviceMessages = encrypted.map { dm -> Sanchr_Messaging_SealedDeviceMessage in
            var sdm = Sanchr_Messaging_SealedDeviceMessage()
            sdm.recipientID = dm.recipientID
            sdm.deviceID = dm.deviceID
            sdm.sealedEnvelope = dm.ciphertext
            return sdm
        }

        var request = Sanchr_Messaging_SendSealedMessageRequest()
        request.deliveryToken = deliveryToken
        request.deviceMessages = deviceMessages
        _ = try await grpcClient.messagingService.sendSealedMessage(request)

        Task { [sealedSenderManager] in await sealedSenderManager.replenishIfNeeded() }
    }

    /// Sends the local user's Profile Key to `recipientUserId` inside a sealed
    /// envelope, so they can decrypt our encrypted profile fields.
    ///
    /// The key is deliberately never uploaded to the server. It previously travelled
    /// in `UpdateProfile` alongside the ciphertext it protects, which handed the
    /// server both halves and made the profile encryption decorative. Distributing
    /// it over the Signal session is what makes that encryption mean anything.
    /// Stores a peer's Profile Key and resolves their display name from it.
    ///
    /// The key alone is not enough: the name lives in ciphertext the client must
    /// fetch (GetUserProfiles) and decrypt. Both happen here, so a real name
    /// appears the moment a key arrives on any inbound message, without waiting
    /// for a full contact sync — and for a peer who is not in the address book,
    /// which is the only path there is. Guarded on the key being new so an
    /// established conversation does not re-fetch on every message.
    func handleReceivedProfileKey(_ key: Data, from userId: String) {
        guard key.count == Self.profileKeyByteCount else {
            SanchrLogger.chat.warning(
                "Ignoring malformed profile key from \(userId.prefix(8)) (\(key.count) bytes)")
            return
        }
        let existing = try? profileKeyStore.contactProfileKey(forUserId: userId)
        let isNewKey = existing != key
        do {
            try profileKeyStore.saveContactProfileKey(key, forUserId: userId)
        } catch {
            SanchrLogger.chat.error(
                "Failed to store profile key from \(userId.prefix(8)): \(error.localizedDescription)")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // A rotated key may carry a new name — let it re-resolve.
            if isNewKey { await self.profileResolutionCoordinator.invalidate(userId) }
            guard await self.profileResolutionCoordinator.begin(userId) else { return }
            let ok = await self.resolveProfile(userId: userId, profileKey: key)
            if ok {
                await self.profileResolutionCoordinator.succeed(userId)
            } else {
                await self.profileResolutionCoordinator.fail(userId)
            }
        }
    }

    /// Resolves display names from Profile Keys we already hold, without waiting
    /// for the peer to send an envelope.
    ///
    /// `handleReceivedProfileKey` only fires on inbound traffic, so a QR-paired
    /// contact — whose key arrived once when the session was set up — reverts to
    /// the placeholder on every cold launch until they next message. This walks
    /// the stored conversations, and for any peer whose key is in the Keychain,
    /// re-runs resolution through the same coordinator. The coordinator's
    /// resolved/in-flight sets make it idempotent: a name that is already
    /// resolved this launch costs nothing, and a stored key that no longer opens
    /// the ciphertext simply fails and is retried on a later load.
    func resolveStoredProfilesIfNeeded() async {
        guard let conversations = try? await localDatabase.fetchConversations() else { return }
        let localUserId = currentUserIdProvider()
        var visited = Set<String>()
        for conversation in conversations {
            for participant in conversation.participants
            where participant.id != localUserId && visited.insert(participant.id).inserted {
                guard
                    let key = try? profileKeyStore.contactProfileKey(forUserId: participant.id),
                    key.count == Self.profileKeyByteCount
                else { continue }
                Task { [weak self] in
                    guard let self else { return }
                    guard await self.profileResolutionCoordinator.begin(participant.id) else {
                        return
                    }
                    let ok = await self.resolveProfile(userId: participant.id, profileKey: key)
                    if ok {
                        await self.profileResolutionCoordinator.succeed(participant.id)
                    } else {
                        await self.profileResolutionCoordinator.fail(participant.id)
                    }
                }
            }
        }
    }

    /// Fetches a peer's encrypted profile, decrypts the display name with their
    /// Profile Key, and writes it onto the local contact row so the conversation
    /// list and header show a real name instead of the server placeholder.
    private func resolveProfile(userId: String, profileKey: Data) async -> Bool {
        do {
            var request = Sanchr_Settings_GetUserProfilesRequest()
            request.userIds = [userId]
            let response = try await grpcClient.settingsService.getUserProfiles(request)
            guard let profile = response.profiles.first(where: { $0.userID == userId }) else {
                return false
            }

            let crypto = ProfileCryptor()
            var resolvedName: String?
            if !profile.encryptedDisplayName.isEmpty {
                resolvedName = try? crypto.decryptField(
                    profile.encryptedDisplayName, profileKey: profileKey, field: .displayName)
            }
            guard let name = resolvedName, !name.isEmpty else {
                // The key does not open this ciphertext: the peer's profile
                // predates the key we hold, or was never uploaded. The phone-number
                // fallback in the normalizer stands.
                return false
            }

            var avatar: URL?
            if !profile.encryptedAvatarURL.isEmpty,
                let urlString = try? crypto.decryptField(
                    profile.encryptedAvatarURL, profileKey: profileKey, field: .avatarURL)
            {
                avatar = URL(string: urlString)
            } else if !profile.avatarURL.isEmpty {
                avatar = URL(string: profile.avatarURL)
            }

            // Merge onto any existing contact so an address-book row keeps its
            // phone number; otherwise create a minimal row for this peer.
            let existing = (try? await localDatabase.fetchContacts())?.first { $0.id == userId }
            let merged = User(
                id: userId,
                phoneNumber: existing?.phoneNumber ?? "",
                displayName: name,
                avatarURL: avatar ?? existing?.avatarURL,
                bio: existing?.bio,
                isVerified: existing?.isVerified ?? false,
                status: existing?.status ?? .offline,
                profileKey: profileKey
            )
            try? await localDatabase.saveContact(merged)

            // Persist the resolved name onto the stored conversation participants,
            // not just the separate contact row. The conversation list, the chat
            // header, and several refresh paths read the participant name straight
            // from the conversation without joining contacts, so writing it here is
            // what makes the name show — and stay — everywhere, rather than only in
            // the one path that runs the contact-join normalizer.
            if let convs = try? await localDatabase.fetchConversations() {
                for var conv in convs
                where conv.participants.contains(where: { $0.id == userId }) {
                    conv.participants = conv.participants.map { p in
                        guard p.id == userId else { return p }
                        var updated = p
                        updated.displayName = name
                        if updated.avatarURL == nil { updated.avatarURL = avatar }
                        return updated
                    }
                    try? await localDatabase.saveConversation(conv)
                }
            }

            // Hop to the main thread: this runs inside a detached Task, and posting
            // a change that drives SwiftUI updates off the main thread is ignored
            // ("Publishing changes from background threads is not allowed").
            await MainActor.run {
                NotificationCenter.default.postContactProfileResolved(userId: userId)
            }
            SanchrLogger.chat.info("Resolved profile name for \(userId.prefix(8))")
            return true
        } catch {
            SanchrLogger.chat.warning(
                "Profile resolve for \(userId.prefix(8)) failed: \(error.localizedDescription)")
            return false
        }
    }

    func sendProfileKey(recipientUserId: String) async throws {
        guard let currentUserId = currentUserIdProvider(), !currentUserId.isEmpty else {
            SanchrLogger.chat.warning("sendProfileKey: missing current user id")
            return
        }
        guard !recipientUserId.isEmpty, recipientUserId != currentUserId else { return }

        let profileKey = try profileKeyStore.ownProfileKey()

        let innerPayload = try sealedSenderManager.encodeInnerPayload(
            conversationId: "",
            messageId: nil,
            contentType: Self.profileKeyContentType,
            content: profileKey,
            isSync: false,
            // Control payloads carry no disappearing timer.
            expiresAfterSecs: nil
        )
        let deliveryToken = try await sealedSenderManager.acquireDeliveryToken()

        let encrypted = try await signalProtocol.encryptForAllDevices(
            plaintext: innerPayload,
            recipientId: recipientUserId
        )
        guard !encrypted.isEmpty else { return }

        let deviceMessages = encrypted.map { dm -> Sanchr_Messaging_SealedDeviceMessage in
            var sdm = Sanchr_Messaging_SealedDeviceMessage()
            sdm.recipientID = dm.recipientID
            sdm.deviceID = dm.deviceID
            sdm.sealedEnvelope = dm.ciphertext
            return sdm
        }

        var request = Sanchr_Messaging_SendSealedMessageRequest()
        request.deliveryToken = deliveryToken
        request.deviceMessages = deviceMessages
        _ = try await grpcClient.messagingService.sendSealedMessage(request)

        profileKeyStore.markOwnProfileKeySent(toUserId: recipientUserId)
        SanchrLogger.chat.debug("Sent profile key to \(recipientUserId.prefix(8))")
        Task { [sealedSenderManager] in await sealedSenderManager.replenishIfNeeded() }
    }

    func fetchPreKeyBundle(userId: String) async throws -> Data {
        SanchrLogger.crypto.info("Fetching pre-key bundle for \(userId.prefix(8))...")

        var request = Sanchr_Keys_GetPreKeyBundleRequest()
        request.userID = userId
        request.deviceID = 1 // Default device

        let response = try await grpcClient.keyService.getPreKeyBundle(request)

        // Serialize the pre-key bundle response to Data for the caller
        return try response.serializedData()
    }

    // MARK: - Sync

    func syncPendingMessages(sinceTimestamp: Int64) async throws -> MessageSyncResult {
        SanchrLogger.chat.info("Syncing pending messages from server")

        var request = Sanchr_Messaging_SyncRequest()
        request.sinceTimestamp = sinceTimestamp

        let stream = grpcClient.messagingService.syncMessages(request)
        var count = 0
        var latestTimestamp = sinceTimestamp
        var appliedCountsByConversation: [String: Int] = [:]

        for try await envelope in stream {
            if Self.shouldDecodeAsSealed(envelope) {
                guard await sealedEnvelopeReplayGate.begin(envelope.messageID) else {
                    continue
                }

                var shouldRememberEnvelope = false
                switch await decodeSealedEnvelope(envelope) {
                case .event(let event):
                    shouldRememberEnvelope = await ackDeliveredEnvelope(
                        messageId: envelope.messageID,
                        conversationId: envelope.conversationID
                    )
                    if case .message(let message) = event {
                        count += 1
                        appliedCountsByConversation[message.conversationId, default: 0] += 1
                        latestTimestamp = max(
                            latestTimestamp,
                            Int64(message.timestamp.timeIntervalSince1970 * 1000)
                        )
                    }
                case .undeliverable(let error):
                    shouldRememberEnvelope = await ackUndeliverableSealedMessage(
                        messageId: envelope.messageID,
                        conversationId: envelope.conversationID,
                        error: error
                    )
                }
                await sealedEnvelopeReplayGate.finish(
                    envelope.messageID,
                    remember: shouldRememberEnvelope
                )
            } else if let message = await decodeMessage(from: envelope) {
                count += 1
                appliedCountsByConversation[message.conversationId, default: 0] += 1
                latestTimestamp = max(
                    latestTimestamp,
                    Int64(message.timestamp.timeIntervalSince1970 * 1000)
                )
            }
        }

        _ = try await flushPendingAcks()

        if count > 0 {
            SanchrLogger.chat.info("Synced \(count) pending message(s) from server")
        }

        return MessageSyncResult(
            appliedCount: count,
            latestTimestamp: latestTimestamp,
            appliedCountsByConversation: appliedCountsByConversation
        )
    }

    func flushPendingAcks() async throws -> Int {
        let pendingAcks = try await localDatabase.fetchPendingMessageAcks(limit: Self.ackBatchSize)
        guard !pendingAcks.isEmpty else { return 0 }

        var request = Sanchr_Messaging_AckMessagesRequest()
        request.messages = pendingAcks.map { ack in
            var ref = Sanchr_Messaging_AckedMessageRef()
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
        var request = Sanchr_Messaging_StartDirectConversationRequest()
        request.recipientID = peerUserId
        let response = try await grpcClient.messagingService.startDirectConversation(request)
        SanchrLogger.chat.info(
            "startDirectConversation: peer=\(peerUserId.prefix(8)) convId=\(response.id.prefix(8))")

        // Hand this peer our Profile Key over the Signal session so they can read
        // our encrypted profile. Best-effort: a failure here must not block opening
        // the conversation, and the key is re-sent on the next profile update.
        Task { [weak self] in
            do {
                try await self?.sendProfileKey(recipientUserId: peerUserId)
            } catch {
                SanchrLogger.chat.warning(
                    "Profile key delivery to \(peerUserId.prefix(8)) failed: \(error.localizedDescription)"
                )
            }
        }

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

    private static func shouldDecodeAsSealed(_ envelope: Sanchr_Messaging_EncryptedEnvelope) -> Bool {
        envelope.contentType == "sealed" || isNilSenderSentinel(envelope)
    }

    private static func isNilSenderSentinel(_ envelope: Sanchr_Messaging_EncryptedEnvelope) -> Bool {
        envelope.senderID == nilUUIDString && envelope.senderDevice == 0
    }

    private static func hasValidNormalSignalAddress(
        _ envelope: Sanchr_Messaging_EncryptedEnvelope
    ) -> Bool {
        !envelope.senderID.isEmpty
            && envelope.senderID != nilUUIDString
            && envelope.senderDevice > 0
    }

    private static func sealedInboundMessage(
        from envelope: Sanchr_Messaging_EncryptedEnvelope
    ) -> Sanchr_Messaging_SealedInboundMessage {
        var sealed = Sanchr_Messaging_SealedInboundMessage()
        sealed.sealedEnvelope = envelope.ciphertext
        sealed.serverTimestamp = envelope.serverTimestamp
        sealed.messageID = envelope.messageID
        return sealed
    }

    private func decodeSealedEnvelope(
        _ envelope: Sanchr_Messaging_EncryptedEnvelope
    ) async -> SealedDecodeOutcome {
        if Self.isNilSenderSentinel(envelope), envelope.contentType != "sealed" {
            SanchrLogger.chat.warning(
                "Routing nil-sender envelope through sealed decrypt msg=\(envelope.messageID.prefix(8)) contentType=\(envelope.contentType)"
            )
        }

        return await decodeSealedMessage(from: Self.sealedInboundMessage(from: envelope))
    }

    private func ackDeliveredEnvelope(messageId: String, conversationId: String) async -> Bool {
        guard !messageId.isEmpty else { return false }

        var ref = Sanchr_Messaging_AckedMessageRef()
        ref.conversationID = conversationId.isEmpty ? Self.nilUUIDString : conversationId
        ref.messageID = messageId

        var request = Sanchr_Messaging_AckMessagesRequest()
        request.messages = [ref]

        do {
            _ = try await grpcClient.messagingService.ackMessages(request)
            return true
        } catch {
            SanchrLogger.chat.warning(
                "Failed to ack delivered envelope \(messageId.prefix(8)): \(error.localizedDescription)"
            )
            return false
        }
    }

    private func ackUndeliverableSealedMessage(
        messageId: String,
        conversationId: String,
        error: Error
    ) async -> Bool {
        guard Self.shouldAckUndeliverableSealedMessage(error) else {
            SanchrLogger.chat.warning(
                "Leaving sealed message unacked for retry msg=\(messageId.prefix(8)) error=\(error.localizedDescription)"
            )
            return false
        }

        let acked = await ackDeliveredEnvelope(messageId: messageId, conversationId: conversationId)
        if acked, let droppedCount = await sealedDropLogLimiter.recordDrop() {
            SanchrLogger.chat.warning(
                "Dropped \(droppedCount) undeliverable sealed message(s); latest=\(messageId.prefix(8))"
            )
        }
        return acked
    }

    static func shouldAckUndeliverableSealedMessage(_ error: Error) -> Bool {
        if case AppError.decryptionFailed(let reason) = error,
           reason.localizedCaseInsensitiveContains("No active sessions") {
            return false
        }

        return true
    }

    private func decodeMessage(from envelope: Sanchr_Messaging_EncryptedEnvelope) async -> Message? {
        guard Self.hasValidNormalSignalAddress(envelope) else {
            SanchrLogger.chat.warning(
                "Skipping envelope with invalid Signal sender address msg=\(envelope.messageID.prefix(8)) sender=\(envelope.senderID.prefix(8)) device=\(envelope.senderDevice) contentType=\(envelope.contentType)"
            )
            return nil
        }

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

    /// Decodes a sealed sender inbound message.
    ///
    /// Flow:
    /// 1. Trial-decrypt the sealed envelope against all known Signal sessions.
    /// 2. Parse the resulting plaintext as an `InnerPayload` (conversation_id,
    ///    content_type, content, is_sync).
    /// 3. If `isSync` is true, save as an outgoing message (multi-device sync).
    /// 4. Otherwise, save as an incoming message and queue a delivery ack.
    /// Decrypts a sealed inbound envelope and returns a `RealtimeEvent`.
    ///
    /// Returns `.presence` for P2P presence envelopes (contentType "presence/v1"),
    /// `.receipt` for sealed read receipts (contentType "receipt/v1"),
    /// or `.message` for regular chat envelopes. Returns `.undeliverable` on decode failure
    /// so the caller can evict poison outbox rows instead of replaying them forever.
    private func decodeSealedMessage(
        from sealed: Sanchr_Messaging_SealedInboundMessage
    ) async -> SealedDecodeOutcome {
        do {
            // 1. Trial-decrypt: iterate all known sessions until one succeeds.
            let result = try await signalProtocol.decryptSealedEnvelope(sealed.sealedEnvelope)

            // 2. Decode the InnerPayload from the decrypted plaintext.
            let innerPayload = try sealedSenderManager.decodeInnerPayload(result.plaintext)

            // Every sealed payload carries the sender's Profile Key
            // (InnerPayload.senderProfileKey). Extract it FIRST — before any
            // content-type branch returns — because the most frequent envelopes
            // (presence, typing, receipts) return early, and those are the best
            // carriers precisely because they are frequent. Storing it here makes
            // key distribution idempotent and self-healing regardless of what the
            // payload turns out to be.
            if let key = innerPayload.senderProfileKey,
                !result.senderUserId.isEmpty,
                result.senderUserId != currentUserIdProvider()
            {
                handleReceivedProfileKey(key, from: result.senderUserId)
            }

            // 3. P2P Presence: route without touching message storage.
            if innerPayload.contentType == "presence/v1" {
                var presenceUpdate = try Sanchr_Messaging_PresenceUpdate(
                    serializedBytes: innerPayload.content
                )
                presenceUpdate.userID = result.senderUserId
                let mappedLastSeen: Date? = presenceUpdate.lastSeen > 0
                    ? Date(timeIntervalSince1970: TimeInterval(presenceUpdate.lastSeen) / 1000.0)
                    : nil
                try? await localDatabase.updateUserPresence(
                    userId: result.senderUserId,
                    status: User.Status(from: presenceUpdate.statusCode),
                    lastSeen: mappedLastSeen
                )
                SanchrLogger.chat.debug(
                    "P2P presence from \(result.senderUserId.prefix(8)) status=\(presenceUpdate.status)"
                )
                return .event(.presence(presenceUpdate))
            }


            // 3b. Profile key distribution: store the sender's key so their encrypted
            // profile fields become readable. Arrives only over the Signal session —
            // a key offered by the server is never trusted.
            if innerPayload.contentType == Self.profileKeyContentType {
                let key = innerPayload.content
                guard key.count == Self.profileKeyByteCount else {
                    SanchrLogger.chat.warning(
                        "Ignoring malformed profile key from \(result.senderUserId.prefix(8)) (\(key.count) bytes)"
                    )
                    return .event(.ignored)
                }
                // Legacy standalone delivery, kept for clients still sending it and
                // for messages already in flight. The envelope path above is now
                // the primary channel. No reciprocation — the envelope carries our
                // key back on our next message.
                handleReceivedProfileKey(key, from: result.senderUserId)
                return .event(.ignored)
            }

            // 4. Sealed read receipt: update local message status, no DB write for new row.
            if innerPayload.contentType == "receipt/v1" {
                let receiptUpdate = try Sanchr_Messaging_ReceiptUpdate(
                    serializedBytes: innerPayload.content
                )
                if let status = Message.DeliveryStatus(rawValue: receiptUpdate.status) {
                    try? await localDatabase.updateMessageStatus(
                        id: receiptUpdate.messageID,
                        status: status
                    )
                    try? await localDatabase.updateConversationLastMessageStatusIfMatches(
                        conversationId: receiptUpdate.conversationID,
                        messageId: receiptUpdate.messageID,
                        status: status
                    )
                }
                SanchrLogger.chat.debug(
                    "Sealed receipt from \(result.senderUserId.prefix(8)) msg=\(receiptUpdate.messageID.prefix(8))"
                )
                return .event(.receipt(receiptUpdate))
            }

            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(sealed.serverTimestamp) / 1000.0
            )

            // 4. Decode the message content from the inner payload.
            let content = decodeContent(innerPayload.content, contentType: innerPayload.contentType)

            // 5. Determine direction: self-sync messages are outgoing.
            let isOutgoing = innerPayload.isSync
            let senderId = result.senderUserId

            let effectiveSenderId: String = isOutgoing
                ? (currentUserIdProvider() ?? senderId)
                : senderId
            let messageId = Self.canonicalSealedMessageId(
                sealedEnvelopeId: sealed.messageID,
                innerPayloadMessageId: innerPayload.messageId
            )

            // Disappearing timer travels inside the envelope. Anchor the deadline to
            // the server timestamp rather than local arrival time, so a device that
            // was offline for a week does not grant itself a fresh full lifetime on
            // the messages it finally syncs.
            let expiresAt: Date? = innerPayload.expiresAfterSecs
                .flatMap { $0 > 0 ? $0 : nil }
                .map { serverTimestamp.addingTimeInterval(TimeInterval($0)) }

            let message = Message(
                id: messageId,
                conversationId: innerPayload.conversationId,
                senderId: effectiveSenderId,
                timestamp: serverTimestamp,
                content: content,
                status: isOutgoing ? .sent : .delivered,
                isOutgoing: isOutgoing,
                expiresAt: expiresAt
            )

            // 6. Ensure the conversation exists locally before saving.
            try? await ensureConversationShellExists(
                conversationId: innerPayload.conversationId,
                senderId: effectiveSenderId,
                serverTimestamp: serverTimestamp
            )

            // 7. Save and (for incoming) queue a delivery ack.
            if isOutgoing {
                try? await localDatabase.saveMessage(message)
            } else {
                try? await localDatabase.saveIncomingMessageAndQueueAck(message)
            }

            // 8. Auto-vault routing (same as regular message path).
            let policy = chatVaultPolicyMirror.policy(for: innerPayload.conversationId)
                ?? .defaults(for: innerPayload.conversationId)
            if !isOutgoing, policy.autoVaultIncoming,
               Self.isVaultEligibleContent(content) {
                Task { [weak self] in
                    await self?.routeIncomingMessageToVault(message)
                }
            }

            SanchrLogger.chat.info(
                "Decoded sealed message \(messageId.prefix(8)) from \(effectiveSenderId.prefix(8)) isSync=\(isOutgoing)"
            )
            return .event(.message(message))
        } catch {
            return .undeliverable(error)
        }
    }

    static func canonicalSealedMessageId(
        sealedEnvelopeId: String,
        innerPayloadMessageId: String?
    ) -> String {
        let candidate = innerPayloadMessageId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, !candidate.isEmpty {
            return candidate
        }
        return sealedEnvelopeId
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
            let uploadedItem = try await vaultRepository.uploadItem(
                data: data,
                name: attachment.filename ?? "vaulted-\(message.id).bin",
                type: vaultType
            )

            // Generate a local thumbnail blob so the Vault browser
            // shows a preview instead of a generic placeholder. The
            // existing VaultRepository.uploadItem doesn't set this
            // today; we patch it onto the local cache row so the
            // Vault tab at least has a preview immediately after
            // auto-vaulting. Remote thumbnail upload is a separate
            // follow-up.
            let thumbnailData: Data? = await Self.generateThumbnailBlob(
                fromDecryptedFile: localFile,
                type: vaultType
            )
            if let thumbnailData {
                var itemWithThumb = uploadedItem
                itemWithThumb.thumbnailData = thumbnailData
                try? await localDatabase.saveVaultItem(itemWithThumb)
            }

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

            // Notify the chat list + detail so the bubble flips to
            // the tombstone state without requiring a nav-away/return.
            await MainActor.run {
                NotificationCenter.default.postConversationStateDidChange(
                    conversationId: message.conversationId
                )
            }

            SanchrLogger.chat.info("Auto-vaulted message \(message.id.prefix(8))")
        } catch {
            SanchrLogger.chat.error(
                "Auto-vault routing failed for \(message.id.prefix(8)): \(error.localizedDescription) — leaving original row"
            )
        }
    }

    /// Generates a small JPEG thumbnail from a decrypted vault file
    /// for the Vault browser preview. Runs off the main thread.
    /// Returns nil for types we don't know how to preview.
    private static func generateThumbnailBlob(
        fromDecryptedFile fileURL: URL,
        type: VaultItem.VaultItemType
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            switch type {
            case .photo:
                guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
                let targetSize = CGSize(width: 300, height: 300)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: targetSize))
                }
                return resized.jpegData(compressionQuality: 0.6)
            case .video:
                if let poster = await MediaThumbnailGenerator.posterFrame(forVideoAt: fileURL) {
                    return poster.jpegData(compressionQuality: 0.6)
                }
                return nil
            case .document, .audio, .note:
                return nil
            }
        }.value
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
        let request = Sanchr_Messaging_GetConversationsRequest()
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

    private func updateConversation(
        conversationId: String,
        mutate: (inout Conversation) -> Void
    ) async throws {
        guard var conversation = try await localDatabase.fetchConversation(id: conversationId) else {
            return
        }
        mutate(&conversation)
        try await localDatabase.saveConversation(conversation)
        await MainActor.run {
            NotificationCenter.default.postConversationStateDidChange(conversationId: conversationId)
        }
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
                guard !isLocal else { return normalizedParticipant }

                let contact = contactsLookup[participant.id]
                if normalizedParticipant.avatarURL == nil {
                    normalizedParticipant.avatarURL = contact?.avatarURL
                }
                normalizedParticipant.displayName = Self.displayTitle(
                    for: participant, contact: contact)
                return normalizedParticipant
            }
            return normalizedConversation
        }
    }

    /// The single rule for what a 1:1 peer is labelled as, so the list, header and
    /// every refresh path agree. Priority, highest first:
    ///
    /// 1. A name saved in the local address book — trusted, shown verbatim.
    ///    (Not wired yet: device-contact names are not captured, so this never
    ///    fires today; it is the reserved top slot for that feature.)
    /// 2. A known phone number for an unsaved peer — shown raw, WhatsApp-style, so
    ///    an unverified stranger reads as a number and not as a trusted name.
    /// 3. A decrypted Profile-Key name — prefixed with "~" to mark it as the
    ///    peer's self-asserted name rather than one the user verified.
    /// 4. "Unknown contact" — never the server's "Sanchr User" placeholder.
    private static func displayTitle(for participant: User, contact: User?) -> String {
        func isPlaceholder(_ name: String) -> Bool {
            name.isEmpty
                || name == participant.id
                || name == User.serverPlaceholderDisplayName
        }

        // A real, decrypted name from either the contact row or the participant.
        let profileName: String? = {
            if let name = contact?.displayName, !isPlaceholder(name) { return name }
            if !isPlaceholder(participant.displayName) { return participant.displayName }
            return nil
        }()

        let phone: String? = {
            if let p = contact?.phoneNumber, !p.isEmpty { return p }
            if !participant.phoneNumber.isEmpty { return participant.phoneNumber }
            return nil
        }()

        if let phone { return phone }
        if let profileName { return "~\(profileName)" }
        return "Unknown contact"
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

    private static func presenceStatusString(_ status: Sanchr_Messaging_PresenceStatus) -> String {
        switch status {
        case .online:
            return "online"
        case .hidden:
            return "hidden"
        case .offline, .unspecified, .UNRECOGNIZED:
            return "offline"
        }
    }
}
