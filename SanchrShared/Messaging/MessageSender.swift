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
    private let crypto: SignalProtocolManagerProtocol
    private let uploader: MediaUploading
    private let grpc: GRPCClientProtocol
    private let coordinator: FileCoordinatorLock
    private let currentUser: CurrentUserProviding
    private let logger: MessageSenderLogging

    // MARK: Init

    public init(
        db: LocalDatabaseProtocol,
        crypto: SignalProtocolManagerProtocol,
        uploader: MediaUploading,
        grpc: GRPCClientProtocol,
        coordinator: FileCoordinatorLock,
        currentUser: CurrentUserProviding,
        logger: MessageSenderLogging = NoopMessageSenderLogger()
    ) {
        self.db = db
        self.crypto = crypto
        self.uploader = uploader
        self.grpc = grpc
        self.coordinator = coordinator
        self.currentUser = currentUser
        self.logger = logger
    }

    // MARK: Public API

    /// Send a plain-text message, holding the cross-process lock for the
    /// duration of the ratchet step + gRPC call.
    public func sendText(
        _ text: String,
        to chatId: String
    ) async throws -> MessageSendReceipt {
        try await coordinator.withLock { [self] in
            try await self.performSendText(text, to: chatId)
        }
    }

    /// Send a media message (with optional caption), holding the cross-process
    /// lock for the duration of upload + ratchet step + gRPC call.
    public func sendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MessageSendReceipt {
        try await coordinator.withLock { [self] in
            try await self.performSendMedia(
                attachment: attachment,
                caption: caption,
                to: chatId,
                progress: progress
            )
        }
    }

    // MARK: Private pipeline (implemented in Task 16)

    private func performSendText(
        _ text: String,
        to chatId: String
    ) async throws -> MessageSendReceipt {
        fatalError("T16: not yet implemented")
    }

    private func performSendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable (Double) -> Void
    ) async throws -> MessageSendReceipt {
        fatalError("T16: not yet implemented")
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
