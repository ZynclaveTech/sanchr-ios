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
            do {
                _ = try await messageSender.sendMedia(
                    attachment: attachment,
                    caption: attachment.caption,
                    to: message.conversationId,
                    progress: { _ in }
                )
            } catch {
                SanchrLogger.chat.error("Media retry failed: \(error.localizedDescription)")
            }

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
