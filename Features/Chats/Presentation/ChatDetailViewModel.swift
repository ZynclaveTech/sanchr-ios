import Foundation
import UserNotifications
import SanchrShared

struct MessageSection: Identifiable, Sendable {
    let id: Date
    let title: String
    var messages: [Message]
}

/// View model for the chat conversation detail screen.
/// Manages messages, input, sending, optimistic updates, and pagination.
/// All outgoing messages are encrypted via Signal Protocol before sending.
/// Incoming messages are decrypted before display.
@MainActor
@Observable
final class ChatDetailViewModel {

    // MARK: - State

    var messages: [Message] = []
    var inputText: String = ""
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var isSending: Bool = false
    var errorMessage: String?
    var conversationInfo: Conversation?
    var isTyping: Bool = false

    /// Message being replied to (shown as quote in composer)
    var replyingToMessage: Message?

    /// Upload progress per message ID (0.0 to 1.0). Removed when complete.
    var uploadProgress: [String: Double] = [:] {
        didSet { bumpTranscriptVersion() }
    }
    /// Upload status label per message ID
    var uploadStatusLabel: [String: String] = [:] {
        didSet { bumpTranscriptVersion() }
    }

    /// Whether the peer is typing.
    var peerIsTyping: Bool = false
    var peerTypingName: String = ""
    var peerPresenceStatus: User.Status = .offline
    var peerLastSeen: Date?
    var peerPresenceHidden: Bool = false
    var showsPresence: Bool = false
    var showsTypingIndicators: Bool = false

    /// Grouped messages by day for stable section headers.
    private(set) var messageSections: [MessageSection] = [] {
        didSet { bumpTranscriptVersion() }
    }
    private(set) var transcriptVersion: UInt64 = 0

    /// Whether there are more messages to load.
    var hasMoreMessages: Bool = true

    private var lastPaginationAnchor: Date?
    private var typingIdleTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var typingIndicatorIsActive = false

    // MARK: - Search State

    var isSearching = false
    var searchQuery = ""
    var searchResults: [Message] = []
    var currentSearchIndex = 0

    // MARK: - Bubble-tap routing

    /// Most recent interaction routed through `route(interaction:)`.
    /// Visible to tests only — the real app reads the coordinators bound
    /// in `ChatDetailView`, not this. Kept because it's the cheapest way
    /// to unit-test routing without coupling the test to the coordinator
    /// implementations (which live in the main-app target).
    var lastRoutedInteraction: MessageInteraction?

    /// Dispatch a bubble-tap interaction to the appropriate coordinator.
    /// Each handler is supplied by `ChatDetailView` because the coordinators
    /// themselves are `@StateObject`s that must live in the view hierarchy;
    /// the view model stays `@Observable` without holding `ObservableObject`
    /// references.
    ///
    /// For `.openMedia`, the method also seeds the gallery with every
    /// image/video message from the current in-memory snapshot in
    /// chronological order via `galleryItems(forTappedMessageId:)`.
    func route(
        interaction: MessageInteraction,
        onOpenGallery: (GallerySeed) -> Void = { _ in },
        onOpenContact: (String, String) -> Void = { _, _ in },
        onOpenLocation: (Double, Double) -> Void = { _, _ in },
        onOpenDocument: (String) -> Void = { _ in }
    ) {
        lastRoutedInteraction = interaction
        switch interaction {
        case .openMedia(let messageId):
            guard let seed = galleryItems(forTappedMessageId: messageId) else {
                SanchrLogger.chat.warning(
                    "route: no gallery seed for \(messageId.prefix(8))")
                return
            }
            onOpenGallery(seed)
        case .openContact(let name, let phoneNumber):
            onOpenContact(name, phoneNumber)
        case .openLocation(let latitude, let longitude):
            onOpenLocation(latitude, longitude)
        case .openDocument(let messageId):
            onOpenDocument(messageId)
        }
    }

    /// Seed the media gallery with every image + video in the current chat
    /// snapshot, ordered chronologically, plus the tapped message's index.
    /// Returns `nil` if the tapped message isn't media or isn't in the
    /// current snapshot. The snapshot is frozen at call time — new messages
    /// arriving while the gallery is open do NOT mutate the pager.
    func galleryItems(forTappedMessageId messageId: String) -> GallerySeed? {
        let ordered = messages
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { msg -> GalleryItem? in
                switch msg.content {
                case .image:
                    return GalleryItem(id: msg.id, kind: .image, message: msg)
                case .video:
                    return GalleryItem(id: msg.id, kind: .video, message: msg)
                default:
                    return nil
                }
            }
        guard let index = ordered.firstIndex(where: { $0.id == messageId }) else {
            return nil
        }
        return GallerySeed(items: ordered, initialIndex: index)
    }

    // MARK: - Conversation Lifecycle

    /// Called when the user enters a conversation.
    /// Clears any pending notifications for this conversation and sets the active conversation
    /// so that foreground notifications for it are suppressed.
    @MainActor
    func onConversationAppear(conversationId: String, pushManager: PushManager) {
        pushManager.setActiveConversation(conversationId)

        // Clear delivered notifications for this conversation
        SanchrNotificationService.clearNotifications(for: conversationId)

        SanchrLogger.chat.info(
            "Entered conversation \(conversationId.prefix(8))..., notifications cleared")
    }

    /// Called when the user leaves a conversation.
    @MainActor
    func onConversationDisappear(pushManager: PushManager) {
        pushManager.setActiveConversation(nil)
    }

    func configurePeer(
        _ peer: User?,
        showsPresence: Bool? = nil,
        showsTypingIndicators: Bool? = nil
    ) {
        if let showsPresence {
            self.showsPresence = showsPresence
        }
        if let showsTypingIndicators {
            self.showsTypingIndicators = showsTypingIndicators
        }

        guard let peer else { return }
        peerPresenceStatus = peer.status
        peerLastSeen = peer.lastSeen
        peerPresenceHidden = false
    }

    // MARK: - Reactions

    var showReactionPickerForMessageId: String?

    func toggleReaction(emoji: String, messageId: String, conversationId: String, userId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        if let reactionIndex = messages[index].reactions.firstIndex(where: { $0.emoji == emoji && $0.userId == userId }) {
            // Remove own reaction
            messages[index].reactions.remove(at: reactionIndex)
        } else {
            // Add reaction
            let reaction = Message.MessageReaction(
                emoji: emoji,
                userId: userId,
                timestamp: Date()
            )
            messages[index].reactions.append(reaction)
        }

        syncMessageSection(for: messages[index])
    }

    func handleRealtimeReaction(messageId: String, userId: String, emoji: String, removed: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        if removed {
            messages[index].reactions.removeAll { $0.emoji == emoji && $0.userId == userId }
        } else {
            let reaction = Message.MessageReaction(emoji: emoji, userId: userId, timestamp: Date())
            if !messages[index].reactions.contains(where: { $0.emoji == emoji && $0.userId == userId }) {
                messages[index].reactions.append(reaction)
            }
        }

        syncMessageSection(for: messages[index])
    }

    // MARK: - Reply State

    func setReply(to message: Message?) {
        replyingToMessage = message
    }

    func clearReply() {
        replyingToMessage = nil
    }

    // MARK: - Load Messages

    func loadMessages(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            messages = try await messageRepository.fetchMessages(
                conversationId: conversationId,
                before: nil,
                limit: 50
            )
            rebuildSections()
            hasMoreMessages = messages.count >= 50
            lastPaginationAnchor = nil
            SanchrLogger.chat.info(
                "Loaded \(self.messages.count) messages for \(conversationId.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to load messages: \(error.localizedDescription)")
        }
    }

    // MARK: - Send Message (E2EE)

    /// Sends the trimmed `inputText` via the shared `MessageSender` actor.
    ///
    /// `MessageSender` is the SOLE writer of outgoing message rows in the
    /// local DB — this view model only manages the in-memory transcript and
    /// the upload-progress dictionary the bubble UI reads. The optimistic
    /// in-memory row is keyed on a fresh UUID; on receipt we replace it with
    /// a `Message` built from the server-confirmed identifiers.
    func sendMessage(
        conversationId: String,
        sessionService: SessionService,
        messageSender: MessageSender
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Clear input immediately for responsive UI
        inputText = ""
        clearReply()
        isSending = true
        defer { isSending = false }

        // Optimistic UI: add message immediately with .sending status. The
        // id used here lives ONLY in the in-memory transcript — the DB row
        // MessageSender writes uses an independent local id, then is replaced
        // by the server-confirmed row inside the actor on success.
        let optimisticMessage = Message.textMessage(
            conversationId: conversationId,
            senderId: sessionService.currentUserId ?? "unknown",
            text: text,
            isOutgoing: true
        )
        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)

        do {
            let receipt = try await messageSender.sendText(text, to: conversationId)
            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(receipt.serverTimestampMs) / 1000.0
            )
            let confirmed = Message(
                id: receipt.messageId,
                conversationId: conversationId,
                senderId: optimisticMessage.senderId,
                timestamp: serverTimestamp,
                content: .text(text),
                status: .sent,
                isOutgoing: true,
                replyToMessageId: optimisticMessage.replyToMessageId
            )
            replaceMessage(id: optimisticMessage.id, with: confirmed)
            SanchrLogger.chat.info("Message sent successfully")
        } catch {
            updateMessage(id: optimisticMessage.id) { $0.status = .failed }
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Media Send

    /// Sends a media attachment (with optional caption) via the shared
    /// `MessageSender` actor. The actor owns the encrypt + upload + gRPC
    /// pipeline AND the local DB writes; this view model only manages the
    /// in-memory optimistic transcript row and the upload-progress dictionary.
    func sendMediaMessage(
        localFileURL: URL,
        mimeType: String,
        contentType: Message.MessageContent,
        conversationId: String,
        caption: String?,
        sessionService: SessionService,
        messageSender: MessageSender
    ) async {
        let senderId = sessionService.currentUserId ?? "unknown"

        // Build the optimistic in-memory row exactly like the legacy path —
        // including the caption applied to the underlying attachment so the
        // bubble renders the user's text under the thumbnail immediately.
        let optimisticContent: Message.MessageContent = {
            guard let caption else { return contentType }
            switch contentType {
            case .image(var a): a.caption = caption; return .image(a)
            case .video(var a): a.caption = caption; return .video(a)
            case .audio(var a): a.caption = caption; return .audio(a)
            case .document(var a): a.caption = caption; return .document(a)
            default: return contentType
            }
        }()

        let optimisticMessage = Message(
            id: UUID().uuidString,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: Date(),
            content: optimisticContent,
            status: .sending,
            isOutgoing: true,
            replyToMessageId: replyingToMessage?.id
        )
        let optimisticId = optimisticMessage.id

        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)
        clearReply()

        // Pluck the underlying attachment so MessageSender has the structured
        // metadata (filename, voice-message flags, dimensions, etc.) it needs
        // to round-trip the wire format faithfully.
        let attachment: Message.MediaAttachment = {
            switch contentType {
            case .image(let a), .video(let a), .audio(let a), .document(let a):
                return a
            default:
                return Message.MediaAttachment(
                    url: localFileURL,
                    encryptionKey: Data(),
                    encryptionIV: Data(),
                    mimeType: mimeType,
                    sizeBytes: 0,
                    thumbnailURL: nil,
                    caption: caption
                )
            }
        }()

        uploadStatusLabel[optimisticId] = "Encrypting..."
        uploadProgress[optimisticId] = 0.0

        do {
            let receipt = try await messageSender.sendMedia(
                attachment: attachment,
                caption: caption,
                to: conversationId
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.uploadProgress[optimisticId] = fraction
                    if fraction >= 1.0 {
                        self.uploadStatusLabel[optimisticId] = "Sending..."
                    } else if fraction > 0 {
                        self.uploadStatusLabel[optimisticId] = "Uploading..."
                    }
                }
            }

            // Cache the sender's local file under the optimistic id so the
            // bubble never has to round-trip its own media through the
            // download pipeline. Mirrors the legacy behaviour exactly.
            let ext = mimeType.contains("png") ? "png"
                : mimeType.hasPrefix("video/") ? "mp4"
                : mimeType.hasPrefix("audio/") ? "m4a"
                : "jpg"
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MediaMessages", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cachedFile = cacheDir.appendingPathComponent("\(optimisticId).\(ext)")
            try? FileManager.default.copyItem(at: localFileURL, to: cachedFile)

            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(receipt.serverTimestampMs) / 1000.0
            )
            // Reuse the optimistic content for the confirmed in-memory row.
            // The post-upload mediaId-URL swap is already persisted in the
            // DB row MessageSender wrote; the in-memory row keeps the local
            // file URL so the sender keeps seeing their own thumbnail
            // instantly without a network round-trip.
            let confirmed = Message(
                id: receipt.messageId,
                conversationId: conversationId,
                senderId: senderId,
                timestamp: serverTimestamp,
                content: optimisticContent,
                status: .sent,
                isOutgoing: true,
                replyToMessageId: optimisticMessage.replyToMessageId
            )
            replaceMessage(id: optimisticId, with: confirmed)
            uploadProgress.removeValue(forKey: optimisticId)
            uploadStatusLabel.removeValue(forKey: optimisticId)
            SanchrLogger.media.info("Media message sent: \(receipt.messageId)")
        } catch {
            updateMessage(id: optimisticId) { $0.status = .failed }
            uploadStatusLabel[optimisticId] = "Failed"
            uploadProgress.removeValue(forKey: optimisticId)
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Media message send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Attachment Intent Routing (Task 13)

    /// Bundle of dependencies + addressing info needed to fulfil an
    /// `AttachmentIntent`. The view layer constructs this once from the
    /// `DependencyContainer` and the active conversation/recipient and passes
    /// it into `send(intent:context:)`.
    struct AttachmentSendContext {
        let conversationId: String
        let recipientId: String
        let sessionService: SessionService
        let messageSender: MessageSender
        let vaultSharingCoordinator: VaultSharingCoordinating
    }

    /// Routes a user-issued `AttachmentIntent` from the attachment picker
    /// through the existing send pipeline. Each case is mapped to the most
    /// appropriate existing send path; cases without a structured payload yet
    /// fall back to a text message and are flagged with TODOs.
    @MainActor
    func send(intent: AttachmentIntent, context: AttachmentSendContext) async {
        switch intent {
        case .photoLibrary(let items):
            for item in items {
                await sendPickedMedia(item, context: context)
            }

        case .capturedMedia(let capture):
            await sendCapturedMedia(capture, context: context)

        case .file(let file):
            // Reuse the media pipeline; documents flow through the same
            // upload + encryption path with a non-image MIME type.
            await sendMediaMessage(
                localFileURL: file.url,
                mimeType: file.mimeType,
                contentType: .document({
                    var a = Message.MediaAttachment(
                        url: file.url,
                        encryptionKey: Data(),
                        encryptionIV: Data(),
                        mimeType: file.mimeType,
                        sizeBytes: file.sizeBytes,
                        thumbnailURL: nil,
                        caption: nil
                    )
                    a.filename = file.filename
                    return a
                }()),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender
            )

        case .contact(let stripped):
            // TODO: replace with structured contact message once a contact
            // MessageContent variant + proto exists. For now we send a text
            // fallback so the picker round-trip is observable end-to-end.
            await sendTextFallback(Self.contactFallbackText(stripped), context: context)

        case .location(let payload):
            // TODO: replace with structured location message + proto. We are
            // forbidden from reverse-geocoding (privacy contract), so the
            // text fallback only contains the raw lat/long.
            await sendTextFallback(Self.locationFallbackText(payload), context: context)

        case .vaultItem(let item):
            // Flow C: user picked a vault item from the chat attachment
            // picker. The forward-secure vault rewrite made it
            // impossible to cross-reference a vault item from a chat
            // (the recipient has no AccessK_vault for it), so the only
            // technically sound path is download + re-upload as a
            // fresh chat attachment. VaultSharingCoordinator owns that
            // pipeline; here we just delegate and surface any error
            // into `errorMessage`.
            do {
                _ = try await context.vaultSharingCoordinator.reshareToCurrentChat(
                    item: item,
                    conversationId: context.conversationId
                )
                SanchrLogger.chat.info(
                    "vault reshare: sent \(item.id.prefix(8)) to \(context.conversationId.prefix(8))"
                )
            } catch {
                errorMessage = error.localizedDescription
                SanchrLogger.chat.error(
                    "vault reshare failed for \(item.id.prefix(8)): \(error.localizedDescription)"
                )
            }

        case .voice(let clip):
            // Voice notes flow through the same media upload pipeline as any
            // other audio attachment. The voice-specific metadata
            // (isVoiceMessage / audioDurationMs / audioWaveform) is stamped
            // onto the optimistic attachment and re-applied after the
            // upload's URL swap by sendMediaMessage's preservation block.
            let filename = "voice-\(Int(Date().timeIntervalSince1970 * 1000)).m4a"
            let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: clip.url.path)[.size] as? Int64) ?? 0
            var a = Message.MediaAttachment(
                url: clip.url,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: "audio/mp4",
                sizeBytes: sizeBytes,
                thumbnailURL: nil,
                caption: nil
            )
            a.filename = filename
            a.isVoiceMessage = true
            a.audioDurationMs = clip.durationMs
            a.audioWaveform = clip.waveform
            await sendMediaMessage(
                localFileURL: clip.url,
                mimeType: "audio/mp4",
                contentType: .audio(a),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender
            )
        }
    }

    /// Pure formatting helper for the contact text-fallback. Exposed for tests.
    ///
    /// Format: `[Contact] <name>` or `[Contact] <name>|<phone>`. Phone is
    /// appended when the stripped contact has at least one number so the
    /// receiver's bubble viewer can offer Message-on-Sanchr / Call / SMS
    /// / Save actions. Name-only payloads still parse for backward
    /// compatibility with older clients.
    static func contactFallbackText(_ stripped: StrippedContact) -> String {
        if let phone = stripped.phoneNumbers.first, !phone.isEmpty {
            return "[Contact] \(stripped.displayName)|\(phone)"
        }
        return "[Contact] \(stripped.displayName)"
    }

    /// Pure formatting helper for the location text-fallback. Exposed for tests.
    /// MUST NOT include any reverse-geocoded place data (privacy contract).
    static func locationFallbackText(_ payload: LocationPayload) -> String {
        "[Location] \(payload.latitude),\(payload.longitude)"
    }

    /// Stages a `CapturedMedia` blob to a temp file and returns the URL +
    /// derived MIME type. Exposed for tests so we can assert the
    /// pass-through-bytes contract without spinning up the full send pipeline.
    static func stageCapturedMediaForTesting(_ capture: CapturedMedia) throws -> (url: URL, mimeType: String) {
        let isVideo = capture.kind == .video
        let ext = isVideo ? "mp4" : "jpg"
        let mimeType = isVideo ? "video/mp4" : "image/jpeg"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        try capture.data.write(to: tempURL)
        return (tempURL, mimeType)
    }

    private func sendPickedMedia(_ item: PickedMedia, context: AttachmentSendContext) async {
        let ext = item.mimeType.contains("png") ? "png"
            : item.mimeType.hasPrefix("video/") ? "mp4"
            : "jpg"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")

        // PhotosLibrarySource.loadVideo returns PickedMedia with an EMPTY
        // `data` and a populated `fileURL` pointing at an already-exported
        // local file; `loadPhoto` does the opposite (data present,
        // fileURL nil). Copy / write runs OFF the main actor — videos can
        // be large and blocking the main thread produces the "should not
        // be called on the main thread" warning plus an unresponsive UI
        // that looks like a crash.
        let itemData = item.data
        let itemFileURL = item.fileURL
        let stagingResult: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
            do {
                if let sourceURL = itemFileURL {
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                    let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                    let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
                    return .success(size)
                } else {
                    try itemData.write(to: tempURL)
                    return .success(Int64(itemData.count))
                }
            } catch {
                return .failure(error)
            }
        }.value

        let stagedSize: Int64
        switch stagingResult {
        case .success(let size):
            stagedSize = size
        case .failure(let error):
            SanchrLogger.chat.error("Failed to stage picked media: \(error.localizedDescription)")
            return
        }

        let attachment = Message.MediaAttachment(
            url: tempURL,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: item.mimeType,
            sizeBytes: stagedSize,
            thumbnailURL: nil,
            caption: nil
        )

        let content: Message.MessageContent
        switch item.kind {
        case .photo: content = .image(attachment)
        case .video: content = .video(attachment)
        }

        await sendMediaMessage(
            localFileURL: tempURL,
            mimeType: item.mimeType,
            contentType: content,
            conversationId: context.conversationId,
            caption: nil,
            sessionService: context.sessionService,
            messageSender: context.messageSender
        )
    }

    private func sendCapturedMedia(_ capture: CapturedMedia, context: AttachmentSendContext) async {
        let isVideo = capture.kind == .video
        let ext = isVideo ? "mp4" : "jpg"
        let mimeType = isVideo ? "video/mp4" : "image/jpeg"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            // Pass through bytes as-is; do not re-encode.
            try capture.data.write(to: tempURL)
        } catch {
            SanchrLogger.chat.error("Failed to stage captured media: \(error.localizedDescription)")
            return
        }

        let attachment = Message.MediaAttachment(
            url: tempURL,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mimeType,
            sizeBytes: Int64(capture.data.count),
            thumbnailURL: nil,
            caption: nil
        )

        let content: Message.MessageContent = isVideo ? .video(attachment) : .image(attachment)

        await sendMediaMessage(
            localFileURL: tempURL,
            mimeType: mimeType,
            contentType: content,
            conversationId: context.conversationId,
            caption: nil,
            sessionService: context.sessionService,
            messageSender: context.messageSender
        )
    }

    private func sendTextFallback(_ text: String, context: AttachmentSendContext) async {
        inputText = text
        await sendMessage(
            conversationId: context.conversationId,
            sessionService: context.sessionService,
            messageSender: context.messageSender
        )
    }

    // MARK: - Receive & Decrypt Incoming Message

    /// Decrypts an incoming encrypted envelope and appends the plaintext message to the list.
    func handleIncomingEnvelope(
        _ envelope: Vync_Messaging_EncryptedEnvelope,
        signalProtocol: SignalProtocolManagerProtocol
    ) async {
        do {
            let plaintext = try await signalProtocol.decryptEnvelope(envelope)
            guard let text = String(data: plaintext, encoding: .utf8) else {
                SanchrLogger.chat.error("Failed to decode decrypted plaintext as UTF-8")
                return
            }

            let incomingMessage = Message(
                id: envelope.messageID,
                conversationId: envelope.conversationID,
                senderId: envelope.senderID,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(envelope.serverTimestamp) / 1000),
                content: .text(text),
                status: .delivered,
                isOutgoing: false
            )
            appendMessageChronologically(incomingMessage)
            SanchrLogger.chat.info(
                "Decrypted and displayed incoming message \(envelope.messageID.prefix(8))")
        } catch {
            SanchrLogger.chat.error(
                "Failed to decrypt incoming message: \(error.localizedDescription)")
            // Insert a system message indicating decryption failure
            let errorMsg = Message(
                id: envelope.messageID,
                conversationId: envelope.conversationID,
                senderId: envelope.senderID,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(envelope.serverTimestamp) / 1000),
                content: .system(.identityKeyChanged),
                status: .delivered,
                isOutgoing: false
            )
            appendMessageChronologically(errorMsg)
        }
    }

    // MARK: - Load More (Pagination)

    /// Loads older messages for infinite scroll.
    func loadMore(conversationId: String, messageRepository: MessageRepositoryProtocol) async {
        guard !isLoadingMore, hasMoreMessages, let oldest = messages.first else { return }
        guard lastPaginationAnchor != oldest.timestamp else { return }
        isLoadingMore = true
        lastPaginationAnchor = oldest.timestamp

        defer { isLoadingMore = false }

        do {
            let olderMessages = try await messageRepository.fetchMessages(
                conversationId: conversationId,
                before: oldest.timestamp,
                limit: 30
            )
            if olderMessages.isEmpty {
                hasMoreMessages = false
            } else {
                let existingIds = Set(messages.map(\.id))
                let deduped = olderMessages.filter { !existingIds.contains($0.id) }
                messages.insert(contentsOf: deduped, at: 0)
                rebuildSections()
            }
        } catch {
            SanchrLogger.chat.error("Load more failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Retry Failed Message

    func retryMessage(
        _ message: Message,
        sessionService: SessionService,
        messageSender: MessageSender
    ) async {
        guard message.status == .failed, case .text(let text) = message.content else { return }

        // Remove the failed message
        messages.removeAll { $0.id == message.id }
        rebuildSections()

        // Re-send
        inputText = text
        await sendMessage(
            conversationId: message.conversationId,
            sessionService: sessionService,
            messageSender: messageSender
        )
    }

    // MARK: - Delete Message

    func deleteMessage(
        _ message: Message,
        forEveryone: Bool,
        messageRepository: MessageRepositoryProtocol,
        chatDataSource: ChatDataSource
    ) async {
        do {
            if forEveryone {
                try await chatDataSource.deleteMessage(
                    conversationID: message.conversationId,
                    messageID: message.id
                )
            }
            try await messageRepository.deleteMessage(id: message.id, forEveryone: forEveryone)
            messages.removeAll { $0.id == message.id }
            rebuildSections()
            SanchrLogger.chat.info("Deleted message \(message.id.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Typing Indicator

    func sendTypingIndicator(
        conversationId: String,
        isTyping: Bool,
        messageRepository: MessageRepositoryProtocol
    ) async {
        do {
            try await messageRepository.sendTypingIndicator(
                conversationId: conversationId,
                isTyping: isTyping
            )
        } catch {
            // Typing indicator failures are non-critical
        }
    }

    func handleInputTextChanged(
        _ newValue: String,
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) {
        typingIdleTask?.cancel()
        let hasText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard hasText else {
            Task {
                await stopTypingIndicator(
                    conversationId: conversationId,
                    messageRepository: messageRepository
                )
            }
            return
        }

        if !typingIndicatorIsActive {
            Task {
                await setTypingIndicator(
                    true,
                    conversationId: conversationId,
                    messageRepository: messageRepository
                )
            }
        }

        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.stopTypingIndicator(
                conversationId: conversationId,
                messageRepository: messageRepository
            )
        }
    }

    func stopTypingIndicator(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        await setTypingIndicator(
            false,
            conversationId: conversationId,
            messageRepository: messageRepository
        )
    }

    func handleRealtimeMessage(_ message: Message) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        appendMessageChronologically(message)
    }

    func handleTypingIndicator(_ indicator: Vync_Messaging_TypingIndicator) {
        guard showsTypingIndicators else {
            peerIsTyping = false
            peerTypingName = ""
            return
        }

        peerIsTyping = indicator.isTyping
        peerTypingName = indicator.userID
    }

    func handlePresenceUpdate(_ update: Vync_Messaging_PresenceUpdate, participantId: String?) {
        guard let participantId, update.userID == participantId else { return }

        switch update.statusCode {
        case .online:
            peerPresenceHidden = false
            peerPresenceStatus = .online
            peerLastSeen = nil

        case .hidden:
            peerPresenceHidden = true
            peerPresenceStatus = .offline
            peerLastSeen = nil

        case .offline, .unspecified, .UNRECOGNIZED:
            peerPresenceHidden = false
            peerPresenceStatus = .offline
            peerLastSeen = update.lastSeen > 0
                ? Date(timeIntervalSince1970: TimeInterval(update.lastSeen) / 1000)
                : nil
        }
    }

    func handleReceipt(_ receipt: Vync_Messaging_ReceiptUpdate) {
        guard let index = messages.firstIndex(where: { $0.id == receipt.messageID }) else { return }
        if let status = Message.DeliveryStatus(rawValue: receipt.status) {
            messages[index].status = status
            syncMessageSection(for: messages[index])
        }
    }

    // MARK: - Search

    func scheduleSearch(
        conversationId: String,
        query: String,
        localDatabase: LocalDatabaseProtocol
    ) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            currentSearchIndex = 0
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let results = try await localDatabase.searchMessages(
                    conversationId: conversationId,
                    query: query
                )

                await MainActor.run {
                    guard let self, self.searchQuery == query else { return }
                    self.searchResults = results
                    self.currentSearchIndex = 0
                }
            } catch {
                await MainActor.run {
                    guard let self, self.searchQuery == query else { return }
                    SanchrLogger.chat.error("Search failed: \(error.localizedDescription)")
                    self.searchResults = []
                }
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = []
        currentSearchIndex = 0
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
    }

    var currentSearchResultId: String? {
        guard !searchResults.isEmpty else { return nil }
        return searchResults[currentSearchIndex].id
    }

    private func setTypingIndicator(
        _ isTyping: Bool,
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        guard typingIndicatorIsActive != isTyping else { return }
        typingIndicatorIsActive = isTyping
        await sendTypingIndicator(
            conversationId: conversationId,
            isTyping: isTyping,
            messageRepository: messageRepository
        )
    }

    private func updateMessage(id: String, mutate: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messages[index].timestamp
        mutate(&messages[index])
        syncMessageSection(for: messages[index], previousTimestamp: previousTimestamp)
    }

    private func replaceMessage(id: String, with message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let previousTimestamp = messages[index].timestamp
        messages[index] = message
        syncMessageSection(for: message, previousTimestamp: previousTimestamp)
    }

    private func appendMessageChronologically(_ message: Message) {
        if let lastMessage = messages.last, message.timestamp < lastMessage.timestamp {
            messages.append(message)
            messages.sort { $0.timestamp < $1.timestamp }
            rebuildSections()
            return
        }

        messages.append(message)
        appendMessageToSections(message)
    }

    private func appendMessageToSections(_ message: Message) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: message.timestamp)

        if let lastIndex = messageSections.indices.last {
            if messageSections[lastIndex].id == day {
                messageSections[lastIndex].messages.append(message)
                return
            }

            if messageSections[lastIndex].id < day {
                messageSections.append(
                    MessageSection(
                        id: day,
                        title: sectionTitle(for: day, calendar: calendar),
                        messages: [message]
                    )
                )
                return
            }
        }

        if messageSections.isEmpty {
            messageSections = [
                MessageSection(
                    id: day,
                    title: sectionTitle(for: day, calendar: calendar),
                    messages: [message]
                )
            ]
            return
        }

        rebuildSections()
    }

    private func syncMessageSection(for message: Message, previousTimestamp: Date? = nil) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: message.timestamp)

        if let previousTimestamp,
           calendar.startOfDay(for: previousTimestamp) != day
        {
            rebuildSections()
            return
        }

        guard let sectionIndex = messageSections.firstIndex(where: { $0.id == day }),
              let messageIndex = messageSections[sectionIndex].messages.firstIndex(where: {
                  $0.id == message.id
              })
        else {
            rebuildSections()
            return
        }

        messageSections[sectionIndex].messages[messageIndex] = message
    }

    private func rebuildSections() {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: messages) { message in
            calendar.startOfDay(for: message.timestamp)
        }

        messageSections = grouped
            .map { day, messages in
                MessageSection(
                    id: day,
                    title: sectionTitle(for: day, calendar: calendar),
                    messages: messages.sorted { $0.timestamp < $1.timestamp }
                )
            }
            .sorted { $0.id < $1.id }
    }

    private func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "Today"
        }
        if calendar.isDateInYesterday(day) {
            return "Yesterday"
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func bumpTranscriptVersion() {
        transcriptVersion &+= 1
    }
}

// MARK: - Gallery DTOs

/// Frozen gallery page list + starting index produced by
/// `ChatDetailViewModel.galleryItems(forTappedMessageId:)` and consumed by
/// `MediaGalleryCoordinator` (added in Phase 2).
struct GallerySeed: Equatable {
    let items: [GalleryItem]
    let initialIndex: Int
}

struct GalleryItem: Identifiable, Equatable {
    enum Kind: Equatable { case image, video }
    let id: String            // messageId
    let kind: Kind
    let message: Message
}
