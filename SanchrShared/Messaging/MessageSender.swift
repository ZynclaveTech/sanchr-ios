import Foundation

// MARK: - MessageSendReceipt

/// Result of a successful send — the authoritative identifiers returned by
/// the server plus the chat the message belongs to. Carried back to callers
/// (both `ChatDetailViewModel` in the main app and `ShareSendCoordinator` in
/// the share extension) so they can reconcile optimistic UI state.
public struct MessageSendReceipt: Sendable, Equatable {
    public let chatId: String
    public let messageId: String
    public let serverTimestampMs: Int64

    public init(chatId: String, messageId: String, serverTimestampMs: Int64) {
        self.chatId = chatId
        self.messageId = messageId
        self.serverTimestampMs = serverTimestampMs
    }
}

// MARK: - MessageSenderLogging

/// Minimal logger surface that `MessageSender` can use without depending on
/// the main app's `os.Logger`-backed `SanchrLogger` (which references
/// subsystems the share extension must not import).
///
/// All methods are synchronous and non-throwing so they are safe to call from
/// any isolation domain.
public protocol MessageSenderLogging: Sendable {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

/// No-op implementation for tests and privacy-sensitive paths where the
/// share extension must not emit diagnostics.
public struct NoopMessageSenderLogger: MessageSenderLogging {
    public init() {}
    public func debug(_ message: String) {}
    public func info(_ message: String) {}
    public func warning(_ message: String) {}
    public func error(_ message: String) {}
}

// MARK: - CurrentUserProviding

/// Lightweight seam giving `MessageSender` access to "who am I" without
/// dragging in the main app's `SessionService` (which is `@MainActor`-bound
/// and references app-only types). Both the main-app adapter and a
/// share-extension adapter conform to this.
///
/// The accessor is `async` so adapters that hold main-actor-isolated state
/// can hop safely; sync implementations just `return` immediately.
public protocol CurrentUserProviding: Sendable {
    /// The currently authenticated user's stable ID. Returns `nil` if no
    /// session is active — callers must treat that as a hard send failure.
    var currentUserId: String? { get async }
}

// MARK: - MediaUploading

/// Outcome of a media upload that `MessageSender` needs in order to build
/// the outgoing encrypted envelope and swap the local file URL for the
/// `sanchr-media://<mediaId>` reference used in persisted messages.
public struct MediaUploadOutcome: Sendable, Equatable {
    public let mediaId: String
    public let remoteURL: String
    public let thumbnailRemoteURL: String?
    /// Size of the encrypted ciphertext blob actually PUT to S3 (used by the
    /// receiver for download progress / range validation).
    public let encryptedFileSize: Int64
    /// Original plaintext file size in bytes.
    public let plaintextFileSize: Int64
    /// 32-byte AES-256 media key (ratchet-derived) the receiver needs to
    /// decrypt the ciphertext. Wrapped in the outgoing E2EE envelope by
    /// `MessageSender`.
    public let encryptionKey: Data
    /// 12-byte AES-GCM nonce used for the encryption.
    public let encryptionNonce: Data
    /// 16-byte AES-GCM authentication tag.
    public let encryptionTag: Data
    /// SHA-256 digest of the plaintext for receiver-side integrity check.
    public let plaintextDigest: Data

    public init(
        mediaId: String,
        remoteURL: String,
        thumbnailRemoteURL: String?,
        encryptedFileSize: Int64,
        plaintextFileSize: Int64,
        encryptionKey: Data,
        encryptionNonce: Data,
        encryptionTag: Data,
        plaintextDigest: Data
    ) {
        self.mediaId = mediaId
        self.remoteURL = remoteURL
        self.thumbnailRemoteURL = thumbnailRemoteURL
        self.encryptedFileSize = encryptedFileSize
        self.plaintextFileSize = plaintextFileSize
        self.encryptionKey = encryptionKey
        self.encryptionNonce = encryptionNonce
        self.encryptionTag = encryptionTag
        self.plaintextDigest = plaintextDigest
    }
}

/// Abstract uploader surface the `MessageSender` actor depends on.
///
/// Defined in SanchrShared (and therefore constrained to extension-safe APIs)
/// so that both the main app's concrete `MediaUploadManager` and test fakes
/// can satisfy it. The real `MediaUploadManager` retains its richer queue /
/// progress-task surface; a thin adapter in the main app conforms to this
/// protocol by funnelling a single upload through that pipeline.
public protocol MediaUploading: Sendable {
    /// Encrypt, upload, and confirm a single file on behalf of a message
    /// send. Implementations MUST NOT mutate any on-disk message rows — that
    /// is `MessageSender`'s job. They report incremental progress via
    /// `progress` on an unspecified isolation domain.
    ///
    /// - Parameters:
    ///   - localFileURL: File URL on disk (in a shared container readable by
    ///     both the main app and the share extension).
    ///   - mimeType: MIME type as determined by the caller.
    ///   - conversationId: Chat the media is bound to (used for ratchet key
    ///     derivation).
    ///   - recipientId: Recipient identity (used for access-key storage).
    ///   - progress: Incremental upload progress callback (`0.0 ... 1.0`).
    ///     Called from an arbitrary isolation domain; implementations MUST
    ///     ensure it is `@Sendable`-safe.
    /// - Returns: Server-assigned identifiers and sizes needed to build the
    ///   outgoing message.
    func uploadMedia(
        localFileURL: URL,
        mimeType: String,
        conversationId: String,
        recipientId: String,
        progress: @Sendable (Double) -> Void
    ) async throws -> MediaUploadOutcome
}

// MARK: - MessageSender

/// Process-and-actor-isolated message send pipeline.
///
/// `MessageSender` owns the `FileCoordinatorLock` for the duration of each
/// send so that Signal-protocol ratchet mutations are atomic across
/// processes (main app vs share extension). It has NO knowledge of UIKit,
/// view models, or `@MainActor` — both `ChatDetailViewModel` in the main
/// app and `ShareSendCoordinator` in the share extension call into the
/// SAME instance of this actor.
///
/// Dependencies are held as protocol existentials (not concrete classes) so
/// tests can substitute fakes and so the actor tracks the dependency-injection
/// style used throughout SanchrShared.
public actor MessageSender {

    // MARK: Dependencies

    private let db: LocalDatabaseProtocol
    private let uploader: MediaUploading
    private let encryptedSender: EncryptedMessageSendingClient
    private let coordinator: FileCoordinatorLock
    private let currentUser: CurrentUserProviding
    private let vaultPolicyResolver: VaultPolicyResolving
    private let logger: MessageSenderLogging

    // MARK: Init

    public init(
        db: LocalDatabaseProtocol,
        uploader: MediaUploading,
        encryptedSender: EncryptedMessageSendingClient,
        coordinator: FileCoordinatorLock,
        currentUser: CurrentUserProviding,
        vaultPolicyResolver: VaultPolicyResolving,
        logger: MessageSenderLogging = NoopMessageSenderLogger()
    ) {
        self.db = db
        self.uploader = uploader
        self.encryptedSender = encryptedSender
        self.coordinator = coordinator
        self.currentUser = currentUser
        self.vaultPolicyResolver = vaultPolicyResolver
        self.logger = logger
    }

    // MARK: Public API

    /// Send a plain-text message. The optimistic DB row is written first,
    /// then the cross-process lock is taken for the duration of the ratchet
    /// step + gRPC call so Signal-protocol mutations stay atomic across the
    /// main app and the share extension.
    public func sendText(
        _ text: String,
        to chatId: String
    ) async throws -> MessageSendReceipt {
        guard let senderId = await currentUser.currentUserId else {
            throw AppError.sessionExpired
        }
        let timestamp = Date()
        let localId = try await insertPendingOutgoingTextRow(
            text: text,
            chatId: chatId,
            authorId: senderId,
            timestamp: timestamp
        )

        do {
            let recipientIds = try await resolveRecipientIds(
                chatId: chatId,
                senderId: senderId
            )
            // Wire format must match `SendMessageUseCase.execute` and the
            // Android `SendMessageUseCase`: raw UTF-8 bytes of the trimmed
            // text, contentType "text". Any deviation breaks interop.
            guard let plaintextData = text.data(using: .utf8) else {
                throw AppError.encryptionFailed(
                    reason: "Failed to encode message text as UTF-8."
                )
            }

            let sendResult = try await coordinator.withLock { [encryptedSender] in
                try await encryptedSender.sendEncryptedMessage(
                    plaintext: plaintextData,
                    contentType: "text",
                    conversationId: chatId,
                    recipientIds: recipientIds,
                    expiresAfterSecs: 0
                )
            }

            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(sendResult.serverTimestampMs) / 1000.0
            )
            let confirmedRow = Message(
                id: sendResult.messageId.isEmpty ? localId : sendResult.messageId,
                conversationId: chatId,
                senderId: senderId,
                timestamp: serverTimestamp,
                content: .text(text),
                status: .sent,
                isOutgoing: true
            )
            try await markMessageAsSent(
                localMessageId: localId,
                confirmedRow: confirmedRow
            )

            logger.info(
                "MessageSender.sendText succeeded chat=\(chatId) local=\(localId) server=\(sendResult.messageId)"
            )
            return MessageSendReceipt(
                chatId: chatId,
                messageId: confirmedRow.id,
                serverTimestampMs: sendResult.serverTimestampMs
            )
        } catch {
            logger.error(
                "MessageSender.sendText failed chat=\(chatId) local=\(localId): \(error.localizedDescription)"
            )
            await markMessageAsFailed(localMessageId: localId, error: error)
            throw error
        }
    }

    /// Send a media message (with optional caption).
    ///
    /// The upload runs OUTSIDE the cross-process lock — uploads are slow and
    /// holding the lock for them would serialize every other process's sends
    /// behind the slowest network. Only the Signal ratchet step + gRPC
    /// `sendMessage` are held under the lock.
    public func sendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MessageSendReceipt {
        guard let senderId = await currentUser.currentUserId else {
            throw AppError.sessionExpired
        }
        let timestamp = Date()
        let localId = try await insertPendingOutgoingMediaRow(
            attachment: attachment,
            caption: caption,
            chatId: chatId,
            authorId: senderId,
            timestamp: timestamp
        )

        do {
            let recipientIds = try await resolveRecipientIds(
                chatId: chatId,
                senderId: senderId
            )
            // For 1:1 the recipient list has exactly one entry; for groups the
            // uploader still derives a single access-key storage identity per
            // upload so we use the first recipient. Group media fan-out would
            // need a separate rework — out of scope here.
            guard let primaryRecipient = recipientIds.first else {
                throw AppError.sessionNotEstablished
            }
            // Step 1 — upload (outside the lock).
            let uploadOutcome = try await uploader.uploadMedia(
                localFileURL: attachment.url,
                mimeType: attachment.mimeType,
                conversationId: chatId,
                recipientId: primaryRecipient,
                progress: progress
            )

            // Step 2 — rebuild the attachment with the mediaId reference and
            // the encryption key/nonce the receiver needs. Mirrors
            // `ChatDetailViewModel.sendMediaMessage` exactly: same field
            // mapping, same voice-message field preservation. Any divergence
            // here causes silent data loss for voice notes / file names.
            guard let mediaIdURL = URL(string: "sanchr-media://\(uploadOutcome.mediaId)") else {
                throw AppError.mediaUploadFailed
            }
            // Read the per-chat vault policy. When viewOnceOutgoing is
            // on, stamp isViewOnce: true on the rebuilt attachment so
            // the receiver's gallery enforces single-view + delete-on-
            // dismiss. The flag rides inside the encrypted envelope —
            // server is blind.
            let vaultPolicy = await vaultPolicyResolver.policy(for: chatId)
            var uploadedAttachment = Message.MediaAttachment(
                url: mediaIdURL,
                encryptionKey: uploadOutcome.encryptionKey,
                encryptionIV: uploadOutcome.encryptionNonce,
                mimeType: attachment.mimeType,
                sizeBytes: uploadOutcome.plaintextFileSize,
                thumbnailURL: uploadOutcome.thumbnailRemoteURL.flatMap(URL.init(string:)),
                caption: caption ?? attachment.caption,
                width: attachment.width,
                height: attachment.height,
                durationSeconds: attachment.durationSeconds,
                blurHash: attachment.blurHash,
                filename: attachment.filename,
                isVoiceMessage: attachment.isVoiceMessage,
                audioDurationMs: attachment.audioDurationMs,
                audioWaveform: attachment.audioWaveform,
                isViewOnce: vaultPolicy.viewOnceOutgoing ? true : nil
            )
            // Defensive: caption setter on the rebuilt struct (already set
            // via init, but mirrors the old code path explicitly).
            if uploadedAttachment.caption == nil, let caption {
                uploadedAttachment.caption = caption
            }

            // Step 3 — build the plaintext payload. Wire format must match
            // `ChatDetailViewModel.sendMediaMessage`: JSON-encoded
            // `Message.MessageContent` enum case carrying the rebuilt
            // attachment, contentType derived from MIME prefix.
            let contentForWire = Self.contentForAttachment(
                uploadedAttachment,
                mimeType: attachment.mimeType
            )
            let plaintextData = try JSONEncoder().encode(contentForWire)
            let contentTypeString: String = {
                if attachment.mimeType.hasPrefix("image/") { return "image" }
                if attachment.mimeType.hasPrefix("video/") { return "video" }
                if attachment.mimeType.hasPrefix("audio/") { return "audio" }
                return "document"
            }()

            // Step 4 — encrypted send under the cross-process lock.
            let sendResult = try await coordinator.withLock { [encryptedSender] in
                try await encryptedSender.sendEncryptedMessage(
                    plaintext: plaintextData,
                    contentType: contentTypeString,
                    conversationId: chatId,
                    recipientIds: recipientIds,
                    expiresAfterSecs: 0
                )
            }

            // Step 5 — flip optimistic row to .sent (or replace it with the
            // server-confirmed id if the server reissued one).
            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(sendResult.serverTimestampMs) / 1000.0
            )
            let confirmedRow = Message(
                id: sendResult.messageId.isEmpty ? localId : sendResult.messageId,
                conversationId: chatId,
                senderId: senderId,
                timestamp: serverTimestamp,
                content: contentForWire,
                status: .sent,
                isOutgoing: true
            )
            try await markMessageAsSent(
                localMessageId: localId,
                confirmedRow: confirmedRow
            )

            logger.info(
                "MessageSender.sendMedia succeeded chat=\(chatId) local=\(localId) server=\(sendResult.messageId) media=\(uploadOutcome.mediaId)"
            )
            return MessageSendReceipt(
                chatId: chatId,
                messageId: confirmedRow.id,
                serverTimestampMs: sendResult.serverTimestampMs
            )
        } catch {
            logger.error(
                "MessageSender.sendMedia failed chat=\(chatId) local=\(localId): \(error.localizedDescription)"
            )
            await markMessageAsFailed(localMessageId: localId, error: error)
            throw error
        }
    }

    // MARK: Recipient resolution

    /// Resolves the set of recipient user IDs for an outgoing message by
    /// loading the conversation from the local DB and filtering the
    /// participant list down to everyone except the sender. `chatId` is a
    /// conversation UUID — NOT a user UUID — so it must never be passed
    /// directly to `encryptForAllDevices`, which expects the peer identity.
    ///
    /// Throws `sessionNotEstablished` if the conversation is missing or
    /// yields no peer participants (e.g. a self-chat or a corrupted row);
    /// treating that as a session failure surfaces cleanly in the existing
    /// send-failure UI without needing a new error case.
    private func resolveRecipientIds(
        chatId: String,
        senderId: String
    ) async throws -> [String] {
        guard let conversation = try await db.fetchConversation(id: chatId) else {
            logger.error("resolveRecipientIds: conversation \(chatId) not found in local DB")
            throw AppError.sessionNotEstablished
        }
        let peers = conversation.participants
            .map(\.id)
            .filter { $0 != senderId }
        guard !peers.isEmpty else {
            logger.error("resolveRecipientIds: conversation \(chatId) has no non-self participants")
            throw AppError.sessionNotEstablished
        }
        return peers
    }

    // MARK: Local DB write helpers (T16c scaffold)
    //
    // `MessageSender` is the SOLE writer of outgoing message rows. View
    // models / coordinators no longer touch the local DB on the send path —
    // they observe the DB after the receipt comes back. These helpers wrap
    // `LocalDatabaseProtocol` so the actor can: (1) insert an optimistic
    // row keyed on a fresh local UUID, (2) on success, replace it with the
    // server-confirmed row, (3) on failure, mark it as `.failed` so the UI
    // can offer a retry affordance.

    /// Insert an outgoing text row in `.sending` state and return the
    /// freshly generated local message ID. The actor uses this ID as the
    /// stable handle for subsequent mark-sent / mark-failed transitions
    /// AND as the `messageId` field of the returned `MessageSendReceipt`.
    private func insertPendingOutgoingTextRow(
        text: String,
        chatId: String,
        authorId: String,
        timestamp: Date
    ) async throws -> String {
        let localId = UUID().uuidString
        let row = Message(
            id: localId,
            conversationId: chatId,
            senderId: authorId,
            timestamp: timestamp,
            content: .text(text),
            status: .sending,
            isOutgoing: true
        )
        try await db.saveMessage(row)
        return localId
    }

    /// Insert an outgoing media row in `.sending` state. The attachment is
    /// stored as-is (with whatever URL the caller chose — typically a local
    /// file URL pre-upload, swapped for `sanchr-media://<id>` post-upload).
    private func insertPendingOutgoingMediaRow(
        attachment: Message.MediaAttachment,
        caption: String?,
        chatId: String,
        authorId: String,
        timestamp: Date
    ) async throws -> String {
        let localId = UUID().uuidString
        var attachmentWithCaption = attachment
        if let caption, attachmentWithCaption.caption == nil {
            attachmentWithCaption.caption = caption
        }
        let content = Self.contentForAttachment(
            attachmentWithCaption,
            mimeType: attachmentWithCaption.mimeType
        )
        let row = Message(
            id: localId,
            conversationId: chatId,
            senderId: authorId,
            timestamp: timestamp,
            content: content,
            status: .sending,
            isOutgoing: true
        )
        try await db.saveMessage(row)
        return localId
    }

    /// Mark the local `.sending` row as `.sent` after the server confirms
    /// receipt.
    ///
    /// Because `Message.id` is immutable, the row's primary key cannot be
    /// rewritten in place. When the server returns the SAME id we generated
    /// locally, we just flip the status column. When the server returns a
    /// DIFFERENT id (the production case today), the caller must construct
    /// a confirmed `Message` with the server-issued id + server timestamp
    /// and pass it via `confirmedRow` — we then delete the optimistic row
    /// and insert the confirmed one. The two writes are not yet wrapped in
    /// a single transaction at the `LocalDatabaseProtocol` boundary; if/when
    /// the protocol grows a `replaceMessage(oldId:with:)` primitive, swap
    /// this helper to use it.
    private func markMessageAsSent(
        localMessageId: String,
        confirmedRow: Message
    ) async throws {
        if confirmedRow.id == localMessageId {
            try await db.updateMessageStatus(id: localMessageId, status: .sent)
        } else {
            try await db.deleteMessage(id: localMessageId)
            try await db.saveMessage(confirmedRow)
        }
    }

    /// Best-effort failure marker. Never throws — a DB write failure here
    /// must not mask the original send error the caller is about to
    /// surface to the UI.
    private func markMessageAsFailed(
        localMessageId: String,
        error: Error
    ) async {
        do {
            try await db.updateMessageStatus(id: localMessageId, status: .failed)
        } catch {
            logger.error(
                "Failed to mark message \(localMessageId) as .failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: Content helpers

    /// Map a `MediaAttachment` to the right `MessageContent` case based on
    /// MIME type. Mirrors `ChatDetailViewModel.contentForAttachment` so
    /// the two stay in lockstep until that view-model copy is removed in
    /// the final T16 cutover.
    private static func contentForAttachment(
        _ attachment: Message.MediaAttachment,
        mimeType: String
    ) -> Message.MessageContent {
        if mimeType.hasPrefix("image/") {
            return .image(attachment)
        } else if mimeType.hasPrefix("video/") {
            return .video(attachment)
        } else if mimeType.hasPrefix("audio/") {
            return .audio(attachment)
        } else {
            return .document(attachment)
        }
    }
}
