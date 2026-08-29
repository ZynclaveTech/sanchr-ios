import Foundation
import SanchrShared

// MARK: - Message Lifecycle
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {

    // MARK: - Load Messages

    func loadMessages(
        conversationId: String,
        unreadCount: Int = 0,
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

            // Compute first unread message for the divider. Only set once per
            // conversation entry; cleared in onConversationDisappear.
            if unreadCount > 0, messages.count > unreadCount {
                firstUnreadMessageId = messages[messages.count - unreadCount].id
            } else {
                firstUnreadMessageId = nil
            }

            SanchrLogger.chat.info(
                "Loaded \(self.messages.count) messages for \(conversationId.prefix(8))")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Failed to load messages: \(error.localizedDescription)")
        }
    }

    // MARK: - Receive & Decrypt Incoming Message

    /// Decrypts an incoming encrypted envelope and appends the plaintext message to the list.
    func handleIncomingEnvelope(
        _ envelope: Sanchr_Messaging_EncryptedEnvelope,
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
            // A decryption failure is a delivery problem, not evidence of a key
            // change. Reporting it as "Security code changed" trained users to
            // dismiss the one warning that should stop them — the real key-change
            // event is emitted from the identity store's pending-change state.
            let errorMsg = Message(
                id: envelope.messageID,
                conversationId: envelope.conversationID,
                senderId: envelope.senderID,
                timestamp: Date(
                    timeIntervalSince1970: TimeInterval(envelope.serverTimestamp) / 1000),
                content: .system(.decryptionFailed),
                status: .delivered,
                isOutgoing: false
            )
            appendMessageChronologically(errorMsg)
        }
    }

    // MARK: - Load More (Pagination)

    /// Loads older messages for infinite scroll.
    /// Number of messages retained once the user is back at the newest end.
    ///
    /// Comfortably more than a screenful, so returning to the bottom and
    /// scrolling up a little never has to re-fetch.
    static let retainedWindowSize = 120

    /// Trimming starts only past this, so an ordinary conversation is never
    /// touched and the work only happens after real paging.
    static let trimThreshold = 400

    /// Drops the oldest messages once the user is back at the newest end.
    ///
    /// Paging up appends without bound, so a long session spent scrolling back
    /// leaves everything loaded for as long as the screen is open — and
    /// `rebuildSections` runs over all of it on every new message, status flip
    /// and reaction.
    ///
    /// This trims only at the bottom, and only ever drops the *oldest*. That
    /// is what makes it safe: everything newer is still present, so nothing can
    /// go missing below, and the dropped messages are exactly what the existing
    /// `before:` pagination re-fetches when the user scrolls up again. No new
    /// fetch direction, and no window that can desynchronise from the live
    /// message stream.
    ///
    /// Returns whether anything was dropped, so callers can log it.
    @discardableResult
    func trimToRecentWindowIfAtBottom(isAtBottom: Bool) -> Bool {
        guard isAtBottom, messages.count > Self.trimThreshold else { return false }

        let dropped = messages.count - Self.retainedWindowSize
        messages.removeFirst(dropped)

        // Older messages exist again by definition — they were just discarded.
        hasMoreMessages = true

        // The pagination anchor and the unread divider may both point at a
        // message that is no longer loaded. Leaving either would page from the
        // wrong place or draw a divider above nothing.
        lastPaginationAnchor = nil
        if let unreadId = firstUnreadMessageId,
           !messages.contains(where: { $0.id == unreadId }) {
            firstUnreadMessageId = nil
        }

        rebuildSections()
        SanchrLogger.chat.info(
            "Trimmed \(dropped) message(s) from the transcript window; \(self.messages.count) retained"
        )
        return true
    }

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
        messageSender: MessageSender,
        mediaCache: MediaDownloadManager
    ) async {
        guard message.status == .failed else { return }

        switch message.content {
        case .text(let text):
            messages.removeAll { $0.id == message.id }
            rebuildSections()
            inputText = text
            await sendMessage(
                conversationId: message.conversationId,
                sessionService: sessionService,
                messageSender: messageSender
            )

        case .image(let media),
             .video(let media),
             .audio(let media),
             .document(let media):
            // Retry resends one attachment; plural retry follows the plural
            // send path.
            guard let attachment = media.first,
                  attachment.url.isFileURL,
                  FileManager.default.fileExists(atPath: attachment.url.path) else {
                SanchrLogger.chat.error("Cannot retry media: local file missing for \(message.id)")
                return
            }
            messages.removeAll { $0.id == message.id }
            rebuildSections()
            // Retry went straight to the sender, which writes a database row
            // but never touches the transcript — so a retried message vanished
            // until something else reloaded the chat, showed no upload
            // progress, and seeded no cache entry. Going through the normal
            // send path inherits all three rather than reimplementing them.
            await sendMediaMessage(
                localFileURL: attachment.url,
                mimeType: attachment.mimeType,
                contentType: message.content,
                conversationId: message.conversationId,
                caption: attachment.caption,
                sessionService: sessionService,
                messageSender: messageSender,
                mediaCache: mediaCache
            )

        default:
            SanchrLogger.chat.warning("Retry not supported for content type in message \(message.id)")
        }
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
}
