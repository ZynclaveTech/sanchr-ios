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

    /// Media actions run from the transcript's own context menu, so the state
    /// they need lives here rather than being threaded up to the root.
    @State private var shareItem: GalleryIdentifiedURLBridge?
    @State private var mediaActionToast: String?

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
            onMediaAction: { action, message in
                Task { await performMediaAction(action, on: message) }
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
        .sheet(item: $shareItem) { wrapped in
            TranscriptActivityView(items: [wrapped.url])
        }
        .overlay(alignment: .bottom) {
            if let mediaActionToast {
                Text(mediaActionToast)
                    .font(SanchrTypography.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
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

    // MARK: - Media Actions

    /// Save, share or copy a photo or video straight from the transcript.
    ///
    /// These used to exist only inside the viewer, which meant opening a
    /// message before you could do anything with it — and on video it meant the
    /// player carried a second toolbar just to offer them.
    ///
    /// The file may not be on disk yet: a message that has never been opened
    /// has only its blurhash and a remote id, so the first step is always to
    /// resolve it, which downloads and decrypts if needed.
    private func performMediaAction(
        _ action: MessageCollectionViewController.MediaMessageAction,
        on message: Message
    ) async {
        guard let attachment = message.content.firstAttachment else { return }

        let url: URL
        do {
            url = try await container.chatMediaResolver.decryptedURL(
                forMessageId: message.id,
                attachment: attachment
            )
        } catch {
            // Almost always "not downloaded and currently offline". Saying so
            // beats a menu item that silently does nothing.
            showMediaToast("Couldn't load the media — try again in a moment.")
            return
        }

        switch action {
        case .saveToPhotos:
            do {
                let isVideo = attachment.mimeType.hasPrefix("video/")
                try await SaveToPhotos.save(fileURL: url, kind: isVideo ? .video : .image)
                showMediaToast(isVideo ? "Video saved to Photos" : "Image saved to Photos")
            } catch {
                showMediaToast(error.localizedDescription)
            }

        case .share:
            shareItem = GalleryIdentifiedURLBridge(url: url)

        case .copy:
            // The image itself for a photo; for a video the file, since the
            // pasteboard has nothing useful to do with a whole movie.
            if attachment.mimeType.hasPrefix("video/") {
                UIPasteboard.general.url = url
                showMediaToast("Video copied")
            } else if let image = UIImage(contentsOfFile: url.path) {
                UIPasteboard.general.image = image
                showMediaToast("Image copied")
            } else {
                showMediaToast("Couldn't copy this media.")
            }
        }
    }

    private func showMediaToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { mediaActionToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(.easeOut(duration: 0.2)) { mediaActionToast = nil }
        }
    }
}

/// Share sheet for media acted on from the transcript.
///
/// The gallery has its own copy of this; they are a handful of lines each and
/// neither view should have to reach into the other's file to present a system
/// sheet.
private struct TranscriptActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

