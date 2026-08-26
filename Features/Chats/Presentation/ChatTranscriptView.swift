import SwiftUI
import SanchrShared

// MARK: - Chat Transcript
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor (Task 6).
// Owns the message-list rendering region + scroll-coordination helpers. State storage
// remains on the root `ChatDetailView` and is passed in via `@Binding`; coordinators
// remain `@StateObject` on the root and are passed as plain references.

@MainActor
struct ChatTranscriptView: View {
    let conversation: Conversation
    @Bindable var messagesState: ChatMessagesState
    var voicePlayback: VoicePlaybackController
    var galleryCoordinator: MediaGalleryCoordinator
    var contactCoordinator: ContactActionCoordinator
    var locationCoordinator: LocationPreviewCoordinator
    var documentCoordinator: DocumentPreviewCoordinator
    @Binding var isScrolledToBottom: Bool
    @Binding var newMessageCountWhileScrolled: Int
    @Binding var transcriptScrollSequence: UInt64
    @Binding var transcriptScrollCommand: TranscriptScrollCommand?
    @Binding var hasPresentedInitialTranscript: Bool
    @Binding var hasScheduledDeferredEntryTasks: Bool
    @Binding var messageToForward: Message?

    /// Narrow callbacks so the transcript doesn't need a reference to the
    /// full view model. The root constructs these once from its owned
    /// `viewModel` (see ChatDetailView.chatBaseView).
    var onReply: (Message) -> Void
    var onReact: (String, String) -> Void
    var onDeleteMessage: (Message) -> Void
    var onRetry: (Message) async -> Void
    var onLoadMore: () async -> Void
    var onRouteInteraction: (MessageInteraction) -> Void

    @Environment(DependencyContainer.self) private var container

    var body: some View {
        MessageCollectionView(
            renderInput: transcriptRenderInput,
            voicePlayback: voicePlayback,
            onInitialPresentation: {
                handleInitialTranscriptPresentation()
            },
            onReply: onReply,
            onReact: { emoji, messageId in
                onReact(emoji, messageId)
            },
            onDeleteMessage: { message in
                onDeleteMessage(message)
            },
            onForward: { message in
                messageToForward = message
            },
            onRetry: { message in
                Task { await onRetry(message) }
            },
            onLoadMore: {
                Task { await onLoadMore() }
            },
            onBubbleTap: onRouteInteraction,
            isScrolledToBottom: $isScrolledToBottom,
            newMessageCountWhileScrolled: $newMessageCountWhileScrolled
        )
        // Transparent background — the chat-level .background on the
        // outer VStack paints either the wallpaper gradient or the
        // surfaceSoft fallback, and the messagesScrollView must let
        // it show through. Setting an opaque colour here would hide
        // every wallpaper behind a flat fill.
        .background(Color.clear)
        .overlay {
            if !hasPresentedInitialTranscript {
                transcriptLoadingPlaceholder
            } else if messagesState.messageSections.isEmpty {
                transcriptEmptyState
            }
        }
        .environment(container)
        .onAppear {
            // Load more is handled by the collection view's scroll delegate
        }
    }

    private var transcriptLoadingPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.sanchrPrimary)
            Text("Opening conversation…")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SanchrExportColors.surfaceSoft.opacity(0.96))
        .allowsHitTesting(false)
    }

    private var transcriptEmptyState: some View {
        VStack(spacing: 8) {
            Text("No messages yet")
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)
            Text("Send a message to start the conversation.")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .allowsHitTesting(false)
    }

    private var transcriptRenderInput: TranscriptRenderInput {
        TranscriptRenderInput(
            sections: messagesState.messageSections,
            uploads: messagesState.uploads,
            uploadsVersion: messagesState.uploads.version,
            version: messagesState.transcriptVersion,
            scrollCommand: transcriptScrollCommand,
            firstUnreadMessageId: messagesState.firstUnreadMessageId
        )
    }

    // MARK: - Scroll coordination

    func nextTranscriptScrollSequence() -> UInt64 {
        transcriptScrollSequence &+= 1
        return transcriptScrollSequence
    }

    func issueTranscriptScroll(to command: TranscriptScrollCommand) {
        transcriptScrollCommand = command
    }

    private func handleInitialTranscriptPresentation() {
        hasPresentedInitialTranscript = true
        scheduleDeferredEntryTasksIfNeeded()
    }

    private func scheduleDeferredEntryTasksIfNeeded() {
        guard !hasScheduledDeferredEntryTasks else { return }
        hasScheduledDeferredEntryTasks = true

        // loadHeaderPreferences() moved to ChatDetailHeaderView's own .task.
        // Only the read-receipt marking remains as a root-owned deferred task.
        Task {
            await markConversationAsReadIfNeeded()
        }
    }

    private func markConversationAsReadIfNeeded() async {
        guard let lastIncomingUnreadMessage = messagesState.messages.last(where: {
            !$0.isOutgoing && $0.status != .read
        }) else { return }

        // Repo gates receipts internally — falls through to local-only when disabled.
        if conversation.type == .oneToOne {
            try? await container.messageRepository.markAsRead(
                conversationId: conversation.id,
                upToMessageId: lastIncomingUnreadMessage.id
            )
        } else {
            try? await container.messageRepository.markAsReadLocally(
                conversationId: conversation.id,
                upToMessageId: lastIncomingUnreadMessage.id
            )
        }

        NotificationCenter.default.postConversationStateDidChange(
            conversationId: conversation.id
        )
    }
}
