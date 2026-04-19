import Foundation
import SanchrShared

// MARK: - Realtime (Typing + Presence)
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {

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

    func handleTypingIndicator(_ indicator: Sanchr_Messaging_TypingIndicator) {
        peerTypingClearTask?.cancel()
        peerTypingClearTask = nil

        guard showsTypingIndicators else {
            peerIsTyping = false
            peerTypingName = ""
            return
        }

        peerIsTyping = indicator.isTyping
        peerTypingName = indicator.userID

        guard indicator.isTyping else { return }

        let userID = indicator.userID
        peerTypingClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.peerTypingName == userID else { return }
                self.peerIsTyping = false
                self.peerTypingName = ""
            }
        }
    }

    func handlePresenceUpdate(_ update: Sanchr_Messaging_PresenceUpdate, participantId: String?) {
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

    func handleReceipt(_ receipt: Sanchr_Messaging_ReceiptUpdate) {
        guard let index = messages.firstIndex(where: { $0.id == receipt.messageID }) else { return }
        if let status = Message.DeliveryStatus(rawValue: receipt.status) {
            messages[index].status = status
            syncMessageSection(for: messages[index])
        }
    }

    // MARK: - Private helpers

    fileprivate func setTypingIndicator(
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
}
