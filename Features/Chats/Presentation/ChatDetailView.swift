import AVFoundation
import Contacts
import ImageIO
import Kingfisher
import PhotosUI
import SwiftUI
import SanchrShared

/// Carries the data needed to show the pre-send caption screen for a photo or video.
/// Conforms to `Identifiable` so it can drive a `.fullScreenCover(item:)`.
private struct PendingMediaSend: Identifiable {
    let id = UUID()
    /// The media content to show in the preview.
    let preview: MediaCaptionView.Preview
    /// Local file URL passed to the upload pipeline.
    let localFileURL: URL
    /// MIME type (e.g. "image/jpeg", "video/mp4").
    let mimeType: String
    /// Pre-built MessageContent enum (url/key fields are placeholders — upload fills them in).
    let contentType: Message.MessageContent
}

/// Carries the original image through the editor flow.
/// Conforms to `Identifiable` so it can drive a `.fullScreenCover(item:)`.
private struct PendingImageEdit: Identifiable {
    let id = UUID()
    let image: UIImage
    let blurHash: String?
}

struct ChatDetailView: View {
    let conversation: Conversation

    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ChatDetailViewModel()
    @FocusState private var isInputFocused: Bool
    @State private var showAttachmentPicker = false
    @State private var showCameraCapture = false
    @State private var showEmojiPicker = false
    @State private var showStickerPicker = false
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var showContactPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showConversationInfo = false
    @State private var isScrolledToBottom = true
    @State private var newMessageCountWhileScrolled = 0
    @State private var transcriptScrollSequence: UInt64 = 0
    @State private var transcriptScrollCommand: TranscriptScrollCommand? = .initialBottom(sequence: 0)
    @State private var hasPresentedInitialTranscript = false
    @State private var hasScheduledDeferredEntryTasks = false
    @State private var voicePlayback = VoicePlaybackController()
    @State private var appearanceTick: UInt64 = 0
    @State private var pendingMediaSend: PendingMediaSend? = nil
    @State private var pendingImageEdit: PendingImageEdit? = nil
    @StateObject private var galleryCoordinator = MediaGalleryCoordinator()
    @StateObject private var contactCoordinator = ContactActionCoordinator(
        contactRepository: BootstrapContactRepository(),
        deviceContactMatcher: { _ in false },
        currentUserId: { nil },
        phoneNormalizer: { $0 }
    )
    @StateObject private var locationCoordinator = LocationPreviewCoordinator()
    @StateObject private var documentCoordinator = DocumentPreviewCoordinator(
        resolver: BootstrapMediaResolver(),
        messageLookup: { _ in nil }
    )
    @State private var presentingNewContact: NewContactPayload?
    @State private var invitePayload: GalleryIdentifiedURLBridge?
    @State private var messageToForward: Message?
    @State private var callErrorMessage: String?
    @State private var conversationActionErrorMessage: String?
    @State private var isConversationArchived: Bool
    @Environment(AppRouter.self) private var router
    @AppStorage("sanchr.enterSendsMessage") private var enterSendsMessage = true

    init(conversation: Conversation) {
        self.conversation = conversation
        _isConversationArchived = State(initialValue: conversation.isArchived)
    }

    private var recipient: User? {
        conversation.participants.first(where: { !$0.isLocalUser })
    }

    var body: some View {
        // appearanceTick is bumped via .onReceive(.chatAppearanceDidChange)
        // below — guarantees body re-evaluation even when @Observable
        // propagation through NavigationStack pop boundaries fails.
        let _ = appearanceTick
        let _ = container.chatAppearance.changeVersion
        return chatViewContent
            .task {
                // Cache-warm the per-chat appearance override BEFORE messages
                // load so the first paint already reflects the override —
                // avoids a global → override flicker.
                await container.chatAppearance.loadOverride(conversationId: conversation.id)
                // Same for the per-chat vault policy so the realtime decode
                // path's lock-protected mirror lookup hits a populated entry
                // when subsequent messages arrive in this chat.
                await container.chatVaultPolicy.loadPolicy(conversationId: conversation.id)
                await viewModel.loadMessages(
                    conversationId: conversation.id,
                    unreadCount: conversation.unreadCount,
                    messageRepository: container.messageRepository
                )
                // If there are unread messages, scroll to the divider instead of bottom.
                if let firstUnreadId = viewModel.firstUnreadMessageId {
                    issueTranscriptScroll(
                        to: .message(id: firstUnreadId, sequence: nextTranscriptScrollSequence())
                    )
                }
                // refreshConversationState() now lives on ChatDetailHeaderView's
                // own .task — it runs when the header subview appears and
                // writes back through the @Binding on isConversationArchived.
                await consumePendingChatAttachmentIfNeeded()
            }
            .onAppear {
                viewModel.configurePeer(recipient)
                if conversation.type == .oneToOne, let recipient {
                    container.realtimeService.trackPresencePeer(recipient.id)
                }
                viewModel.onConversationAppear(
                    conversationId: conversation.id,
                    pushManager: container.pushManager
                )
            }
            .onDisappear {
                viewModel.onConversationDisappear(pushManager: container.pushManager)
                if let recipient {
                    container.realtimeService.untrackPresencePeer(recipient.id)
                }
                // Clear typing indicator when leaving conversation
                Task {
                    await viewModel.stopTypingIndicator(
                        conversationId: conversation.id,
                        messageRepository: container.messageRepository
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sanchrConversationStateDidChange)) { note in
                handleConversationStateDidChange(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimeMessageReceived)) { note in
                handleRealtimeMessageReceived(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimeTypingChanged)) { note in
                handleRealtimeTypingChanged(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimeReceiptUpdated)) { note in
                handleRealtimeReceiptUpdated(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimePresenceUpdated)) { note in
                handleRealtimePresenceUpdated(note)
            }
            .onChange(of: viewModel.inputText) { _, newValue in
                viewModel.handleInputTextChanged(
                    newValue,
                    conversationId: conversation.id,
                    messageRepository: container.messageRepository
                )
            }
            .onChange(of: isInputFocused) { _, focused in
                if !focused {
                    // Keyboard dismissed — stop typing indicator
                    Task {
                        await viewModel.stopTypingIndicator(
                            conversationId: conversation.id,
                            messageRepository: container.messageRepository
                        )
                    }
                } else {
                    // Keyboard appeared — mutually exclusive with attachment, emoji & sticker trays
                    if showAttachmentPicker || showEmojiPicker || showStickerPicker {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showAttachmentPicker = false
                            showEmojiPicker = false
                            showStickerPicker = false
                        }
                    }
                }
            }
            .onChange(of: viewModel.searchQuery) { _, query in
                viewModel.scheduleSearch(
                    conversationId: conversation.id,
                    query: query,
                    localDatabase: container.localDatabase
                )
            }
            .onChange(of: viewModel.currentSearchResultId) { _, messageId in
                guard let messageId else { return }
                issueTranscriptScroll(to: .message(id: messageId, sequence: nextTranscriptScrollSequence()))
            }
    }

    // MARK: - Chat content (split from body to keep type-checker within limits)

    /// The base VStack with appearance/navigation modifiers.
    /// Separated from the sheet/cover layer so the compiler can
    /// type-check each expression independently.
    @ViewBuilder
    private var chatBaseView: some View {
        let appearance = container.chatAppearance.effectiveAppearance(for: conversation.id)
        let wallpaperId = appearance.wallpaperId
        VStack(spacing: 0) {
            header

            if viewModel.isSearching {
                chatSearchBar
            }

            ZStack(alignment: .bottomTrailing) {
                messagesScrollView

                if !isScrolledToBottom {
                    scrollToBottomFAB
                }

                // Reaction picker overlay removed — reactions are in context menu
            }

            if viewModel.showsTypingIndicators && (viewModel.peerIsTyping || viewModel.peerPresenceStatus == .typing) {
                typingPill
            }

            composer

            if showAttachmentPicker {
                AttachmentPickerHost(
                    onIntent: { intent in
                        let ctx = makeAttachmentSendContext()
                        Task { @MainActor in
                            await viewModel.send(intent: intent, context: ctx)
                        }
                    },
                    onRequestAction: { item in
                        switch item {
                        case .camera:
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showAttachmentPicker = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                showCameraCapture = true
                            }
                        case .photos:
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showAttachmentPicker = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                showPhotosPicker = true
                            }
                        case .file:
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showAttachmentPicker = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                showFileImporter = true
                            }
                        case .contact:
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showAttachmentPicker = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                showContactPicker = true
                            }
                        case .gif:
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showAttachmentPicker = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showStickerPicker = true
                                }
                            }
                        case .location:
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showAttachmentPicker = false
                            }
                            let ctx = makeAttachmentSendContext()
                            Task { @MainActor in
                                // Bind to a local to keep the LocationSource alive
                                // across the suspension; the CLLocationManager's
                                // delegate is weak, so a temporary would race ARC.
                                let source = LocationSource()
                                do {
                                    let payload = try await source.requestOneShot()
                                    await viewModel.send(intent: .location(payload), context: ctx)
                                } catch {
                                    SanchrLogger.chat.error("Location request failed: \(error)")
                                }
                            }
                        }
                    }
                )
                .frame(height: 280)
                .background(SanchrExportColors.background)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showEmojiPicker {
                EmojiPickerSheet { emoji in
                    viewModel.inputText.append(emoji)
                }
                .frame(height: 280)
                .background(SanchrExportColors.background)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showStickerPicker {
                StickerPickerSheet(
                    onStickerSelected: { data in
                        let ctx = makeAttachmentSendContext()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showStickerPicker = false
                        }
                        Task { @MainActor in
                            await viewModel.send(intent: .sticker(data), context: ctx)
                        }
                    },
                    onGIFSelected: { url in
                        let ctx = makeAttachmentSendContext()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showStickerPicker = false
                        }
                        Task { @MainActor in
                            await viewModel.send(intent: .gif(url), context: ctx)
                        }
                    }
                )
                .frame(height: 280)
                .background(SanchrExportColors.background)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            Group {
                // For the default wallpaper id (or empty/legacy), keep the
                // existing systemGroupedBackground so dark mode users see
                // the dark surface they expect. Once a non-default
                // wallpaper is picked, paint the gradient instead.
                if wallpaperId == "default" {
                    SanchrExportColors.surfaceSoft
                } else {
                    WallpaperPainter.background(for: wallpaperId)
                }
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(appearance.appearanceMode.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .chatAppearanceDidChange)) { _ in
            appearanceTick &+= 1
        }
        .navigationBarHidden(true)
        .sanchrInteractivePopEnabled()
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showConversationInfo) {
            ConversationInfoView(conversation: conversation, recipient: recipient)
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let ctx = makeAttachmentSendContext()
                Task { @MainActor in
                    do {
                        let picked = try FileSource.makePickedFile(fromSecurityScopedURL: url)
                        await viewModel.send(intent: .file(picked), context: ctx)
                    } catch {
                        SanchrLogger.chat.error("File import failed: \(error)")
                    }
                }
            case .failure(let error):
                SanchrLogger.chat.error("File picker error: \(error)")
            }
        }
    }

    /// Wraps `chatBaseView` with sheet, cover, overlay, and coordinator
    /// modifiers. Separated so the compiler type-checks two smaller
    /// expression trees rather than one giant chain.
    @ViewBuilder
    private var chatViewContent: some View {
        chatBaseView
        .sheet(isPresented: $showContactPicker) {
            ContactPickerHost(
                onPick: { stripped in
                    let ctx = makeAttachmentSendContext()
                    Task { @MainActor in
                        await viewModel.send(intent: .contact(stripped), context: ctx)
                    }
                    showContactPicker = false
                },
                onCancel: { showContactPicker = false }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCameraCapture) {
            CameraCaptureView(
                onCapture: { capture in
                    let ctx = makeAttachmentSendContext()
                    Task { @MainActor in
                        await viewModel.send(intent: .capturedMedia(capture), context: ctx)
                    }
                    showCameraCapture = false
                },
                onCancel: { showCameraCapture = false }
            )
        }
        .fullScreenCover(item: $galleryCoordinator.presentation) { presentation in
            MediaGalleryView(
                presentation: presentation,
                resolver: container.chatMediaResolver,
                onDismiss: { galleryCoordinator.dismiss() }
            )
        }
        .sheet(item: $contactCoordinator.pendingContact) { pending in
            ContactActionSheet(
                pending: pending,
                onMessageOnSanchr: { userId in
                    Task {
                        do {
                            let convId = try await container.messageRepository.startDirectConversation(peerUserId: userId)
                            contactCoordinator.dismiss()
                            router.deepLinkToConversation(conversationId: convId)
                        } catch {
                            SanchrLogger.chat.error("startDirectConversation failed: \(error.localizedDescription)")
                        }
                    }
                },
                onInvite: {
                    contactCoordinator.dismiss()
                    if let url = URL(string: "https://sanchr.io/invite?from=chat") {
                        invitePayload = GalleryIdentifiedURLBridge(url: url)
                    }
                },
                onOpenNewContact: { name, phone in
                    contactCoordinator.dismiss()
                    presentingNewContact = NewContactPayload(name: name, phone: phone)
                },
                onOpenExistingContact: {
                    // Read-only view of an existing CNContact would require
                    // a second roundtrip through CNContactStore to find the
                    // matching CNContact by phone. For now, fall back to the
                    // new-contact sheet which lets the user see + merge.
                    contactCoordinator.dismiss()
                    presentingNewContact = NewContactPayload(
                        name: pending.name,
                        phone: pending.phoneNumber
                    )
                },
                onDismiss: { contactCoordinator.dismiss() }
            )
        }
        .sheet(item: $presentingNewContact) { payload in
            ContactViewControllerHost(
                mode: .newContact(name: payload.name, phone: payload.phone),
                onDismiss: { presentingNewContact = nil }
            )
        }
        .sheet(item: $invitePayload) { payload in
            ChatShareActivityView(items: ["Join me on Sanchr — \(payload.url)"])
        }
        .sheet(item: $messageToForward) { message in
            MessageForwardDestinationPicker(
                localDatabase: container.localDatabase,
                onConversationPicked: { targetId, _ in
                    messageToForward = nil
                    Task {
                        await viewModel.forwardMessage(
                            message,
                            toConversationId: targetId,
                            sessionService: container.sessionService,
                            messageSender: container.messageSender
                        )
                    }
                },
                onCancel: { messageToForward = nil }
            )
        }
        .fullScreenCover(item: $locationCoordinator.presentation) { presentation in
            LocationPreviewView(
                latitude: presentation.latitude,
                longitude: presentation.longitude,
                onDismiss: { locationCoordinator.dismiss() }
            )
        }
        .fullScreenCover(item: $documentCoordinator.presentation) { presentation in
            DocumentPreviewView(
                fileURL: presentation.fileURL,
                onDismiss: { documentCoordinator.dismiss() }
            )
        }
        .fullScreenCover(item: $pendingMediaSend) { payload in
            MediaCaptionView(preview: payload.preview) { caption in
                commitPendingMediaSend(payload, caption: caption)
            } onCancel: {
                pendingMediaSend = nil
            }
        }
        .fullScreenCover(item: $pendingImageEdit) { pending in
            ImageEditorView(sourceImage: pending.image) { editedImage in
                pendingImageEdit = nil
                Task { await commitImageEdit(editedImage, blurHash: pending.blurHash) }
            } onCancel: {
                pendingImageEdit = nil
            }
        }
        .overlay {
            if documentCoordinator.isResolving {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Opening document…")
                                .font(SanchrTypography.caption)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .modifier(ChatViewerHUDModifier())
                    }
            }
        }
        .alert("Couldn't open file", isPresented: Binding(
            get: { documentCoordinator.resolveError != nil },
            set: { if !$0 { documentCoordinator.clearError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(documentCoordinator.resolveError ?? "")
        }
        .alert("Call Failed", isPresented: Binding(
            get: { callErrorMessage != nil },
            set: { if !$0 { callErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(callErrorMessage ?? "")
        }
        .alert("Couldn't update conversation", isPresented: Binding(
            get: { conversationActionErrorMessage != nil },
            set: { if !$0 { conversationActionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversationActionErrorMessage ?? "")
        }
        .task(id: "bubble-viewers-reconfigure") {
            contactCoordinator.reconfigure(
                contactRepository: container.contactRepository,
                deviceContactMatcher: { phone in
                    DeviceContactMatcher.shared.contains(phone: phone)
                },
                currentUserId: { container.sessionService.currentUserId },
                phoneNormalizer: ContactDataSource.normalizePhoneNumber
            )
            // viewModel is a @State-owned reference; the documentCoordinator
            // is a @StateObject on the same view so the capture can't
            // outlive the view. Strong capture is intentional.
            let vm = viewModel
            documentCoordinator.reconfigure(
                resolver: container.chatMediaResolver,
                messageLookup: { id in
                    vm.messages.first(where: { $0.id == id })
                }
            )
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            let selectedItems = items
            selectedPhotoItems = []
            Task {
                for item in selectedItems {
                    await handleSelectedPhoto(item)
                }
            }
        }
    }

    private var header: some View {
        ChatDetailHeaderView(
            conversation: conversation,
            viewModel: viewModel,
            isConversationArchived: $isConversationArchived,
            conversationActionErrorMessage: $conversationActionErrorMessage,
            showConversationInfo: $showConversationInfo,
            callErrorMessage: $callErrorMessage,
            onDismiss: { dismiss() }
        )
    }

    private var chatSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)

                TextField("Search messages...", text: $viewModel.searchQuery)
                    .font(SanchrTypography.messageBubbleText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.scheduleSearch(
                            conversationId: conversation.id,
                            query: viewModel.searchQuery,
                            localDatabase: container.localDatabase
                        )
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .modifier(ChatSearchFieldSurfaceModifier())

            if !viewModel.searchResults.isEmpty {
                SanchrGlassCluster(spacing: 10) {
                    HStack(spacing: 6) {
                        Group {
                            if #available(iOS 26.0, *) {
                                Text("\(viewModel.currentSearchIndex + 1)/\(viewModel.searchResults.count)")
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .sanchrGlass(role: .chip)
                            } else {
                                Text("\(viewModel.currentSearchIndex + 1)/\(viewModel.searchResults.count)")
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                                    .frame(minWidth: 30)
                            }
                        }

                        SanchrIconButton(
                            systemName: "chevron.up",
                            foreground: SanchrExportColors.textSecondary,
                            background: SanchrExportColors.surface,
                            size: 30
                        ) {
                            viewModel.previousSearchResult()
                        }

                        SanchrIconButton(
                            systemName: "chevron.down",
                            foreground: SanchrExportColors.textSecondary,
                            background: SanchrExportColors.surface,
                            size: 30
                        ) {
                            viewModel.nextSearchResult()
                        }
                    }
                }
            }

            Button {
                withAnimation {
                    viewModel.isSearching = false
                    viewModel.clearSearch()
                }
            } label: {
                Text("Cancel")
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrColors.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(SanchrExportColors.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    private var typingPill: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(SanchrExportColors.textTertiary)
                        .frame(width: 6, height: 6)
                }
            }

            if let name = recipient?.displayName.components(separatedBy: " ").first {
                Text("\(name) is typing...")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textTertiary)
                    .italic()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var messagesScrollView: some View {
        MessageCollectionView(
            renderInput: transcriptRenderInput,
            voicePlayback: voicePlayback,
            onInitialPresentation: {
                handleInitialTranscriptPresentation()
            },
            onReply: { message in
                viewModel.setReply(to: message)
            },
            onReact: { emoji, messageId in
                let userId = container.signalProtocol.localUserId
                viewModel.toggleReaction(
                    emoji: emoji,
                    messageId: messageId,
                    conversationId: conversation.id,
                    userId: userId,
                    chatDataSource: container.chatDataSource
                )
            },
            onForward: { message in
                messageToForward = message
            },
            onRetry: { message in
                Task {
                    await viewModel.retryMessage(
                        message,
                        sessionService: container.sessionService,
                        messageSender: container.messageSender
                    )
                }
            },
            onLoadMore: {
                Task {
                    await viewModel.loadMore(
                        conversationId: conversation.id,
                        messageRepository: container.messageRepository
                    )
                }
            },
            onBubbleTap: { interaction in
                viewModel.route(
                    interaction: interaction,
                    onOpenGallery: { seed in
                        galleryCoordinator.present(seed: seed)
                    },
                    onOpenContact: { name, phone in
                        Task { await contactCoordinator.present(name: name, phoneNumber: phone) }
                    },
                    onOpenLocation: { lat, lon in
                        locationCoordinator.present(latitude: lat, longitude: lon)
                    },
                    onOpenDocument: { messageId in
                        Task { await documentCoordinator.open(messageId: messageId) }
                    }
                )
            },
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
            } else if viewModel.messageSections.isEmpty {
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

    private var scrollToBottomFAB: some View {
        Button {
            newMessageCountWhileScrolled = 0
            issueTranscriptScroll(to: .manualBottom(sequence: nextTranscriptScrollSequence()))
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if #available(iOS 26.0, *) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .frame(width: 40, height: 40)
                            .sanchrGlass(
                                role: .floatingAction,
                                interactive: true
                            )
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(SanchrExportColors.surface)
                            .clipShape(Circle())
                            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
                    }
                }

                if newMessageCountWhileScrolled > 0 {
                    Text("\(newMessageCountWhileScrolled)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, 4)
                        .background(SanchrColors.primary)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .transition(.scale.combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: isScrolledToBottom)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            // Reply banner
            if let replyMessage = viewModel.replyingToMessage {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SanchrColors.primary)
                        .frame(width: 3, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(replyMessage.isOutgoing ? "You" : conversation.displayName)
                            .font(SanchrTypography.captionSmall)
                            .fontWeight(.semibold)
                            .foregroundColor(SanchrColors.primary)
                            .lineLimit(1)

                        Text(replyPreviewText(replyMessage))
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.clearReply()
                        }
                    } label: {
                        Group {
                            if #available(iOS 26.0, *) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                                    .frame(width: 24, height: 24)
                                    .sanchrGlass(role: .toolbarButton, interactive: true)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(SanchrExportColors.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SanchrExportColors.line).frame(height: 1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Single-row adaptive composer
            HStack(alignment: .bottom, spacing: 10) {
                // Plus button — opens attachment sheet
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if showAttachmentPicker {
                            showAttachmentPicker = false
                        } else {
                            isInputFocused = false
                            showEmojiPicker = false
                            showAttachmentPicker = true
                        }
                    }
                } label: {
                    Group {
                        if #available(iOS 26.0, *) {
                            Image(systemName: showAttachmentPicker ? "xmark" : "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(SanchrColors.primary)
                                .frame(width: 36, height: 36)
                                .sanchrGlass(
                                    role: .floatingAction,
                                    interactive: true,
                                    prominence: .prominent,
                                    tint: SanchrColors.primary.opacity(0.18)
                                )
                        } else {
                            Image(systemName: showAttachmentPicker ? "xmark" : "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(SanchrColors.primary)
                                .frame(width: 36, height: 36)
                                .background(SanchrColors.primary.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                }
                .buttonStyle(.plain)

                // Text input field
                HStack(spacing: 6) {
                    TextField("Message...", text: $viewModel.inputText, axis: .vertical)
                        .font(SanchrTypography.messageBubbleText)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isInputFocused)
                        .onSubmit {
                            if enterSendsMessage {
                                Task {
                                    await viewModel.sendMessage(
                                        conversationId: conversation.id,
                                        sessionService: container.sessionService,
                                        messageSender: container.messageSender
                                    )
                                }
                            } else {
                                viewModel.inputText += "\n"
                            }
                        }

                    if !hasInput {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if showEmojiPicker {
                                    showEmojiPicker = false
                                } else {
                                    isInputFocused = false
                                    showAttachmentPicker = false
                                    showEmojiPicker = true
                                }
                            }
                        } label: {
                            Image(systemName: showEmojiPicker ? "keyboard" : "face.smiling")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(SanchrExportColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            isInputFocused ? SanchrColors.primary.opacity(0.4) : SanchrExportColors.line.opacity(0.6),
                            lineWidth: 1
                        )
                }

                // Right button: mic (empty) or send (has text)
                if hasInput {
                    // Send button
                    Button {
                        Task {
                            await viewModel.sendMessage(
                                conversationId: conversation.id,
                                sessionService: container.sessionService,
                                messageSender: container.messageSender
                            )
                        }
                    } label: {
                        Group {
                            if #available(iOS 26.0, *) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .sanchrGlass(
                                        role: .floatingAction,
                                        interactive: true,
                                        prominence: .prominent,
                                        tint: SanchrColors.primary
                                    )
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        LinearGradient(
                                            colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .clipShape(Circle())
                                    .shadow(color: SanchrColors.primary.opacity(0.25), radius: 8, x: 0, y: 3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    VoiceMessageComposer(
                        playback: voicePlayback,
                        onActivate: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isInputFocused = false
                                showAttachmentPicker = false
                                showEmojiPicker = false
                            }
                        },
                        onSend: { url, durationMs, waveform in
                            let ctx = makeAttachmentSendContext()
                            Task { @MainActor in
                                await viewModel.send(
                                    intent: .voice(VoiceClip(url: url, durationMs: durationMs, waveform: waveform)),
                                    context: ctx
                                )
                            }
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: hasInput)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(SanchrExportColors.background.ignoresSafeArea(edges: .bottom))
        .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: -4)
    }

    private var hasInput: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var transcriptRenderInput: TranscriptRenderInput {
        TranscriptRenderInput(
            sections: viewModel.messageSections,
            uploadProgress: viewModel.uploadProgress,
            uploadStatusLabel: viewModel.uploadStatusLabel,
            version: viewModel.transcriptVersion,
            scrollCommand: transcriptScrollCommand,
            firstUnreadMessageId: viewModel.firstUnreadMessageId
        )
    }

    private func nextTranscriptScrollSequence() -> UInt64 {
        transcriptScrollSequence &+= 1
        return transcriptScrollSequence
    }

    private func issueTranscriptScroll(to command: TranscriptScrollCommand) {
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
        guard let lastIncomingUnreadMessage = viewModel.messages.last(where: {
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

    private func generateVideoThumbnail(videoURL: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            let asset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)

            let time = CMTime(seconds: 1, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil as URL?
            }

            let uiImage = UIImage(cgImage: cgImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.7) else { return nil }

            let thumbURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)_thumb.jpg")
            try? jpegData.write(to: thumbURL)
            return thumbURL
        }.value
    }

    private func replyPreviewText(_ message: Message) -> String {
        switch message.content {
        case .text(let text): return text
        case .image(_): return "Photo"
        case .video(_): return "Video"
        case .audio(_): return "Voice message"
        case .document(_): return "Document"
        case .location: return "Location"
        case .contact(let name, _): return "Contact: \(name)"
        case .system(let event): return event.rawValue
        }
    }

    /// Builds the dependency bundle the view model needs to fulfil an
    /// `AttachmentIntent`. Captured by value at call time so the resulting
    /// closure-friendly struct doesn't accidentally retain SwiftUI state.
    @MainActor
    private func makeAttachmentSendContext() -> ChatDetailViewModel.AttachmentSendContext {
        ChatDetailViewModel.AttachmentSendContext(
            conversationId: conversation.id,
            recipientId: recipient?.id ?? "",
            sessionService: container.sessionService,
            messageSender: container.messageSender,
            vaultSharingCoordinator: container.vaultSharingCoordinator
        )
    }

    @MainActor
    private func consumePendingChatAttachmentIfNeeded() async {
        guard let intent = router.consumePendingChatAttachment(for: conversation.id) else { return }
        let ctx = makeAttachmentSendContext()
        await viewModel.send(intent: intent, context: ctx)
    }

    // MARK: - Notification handlers (extracted to reduce body type-check complexity)

    private func handleConversationStateDidChange(_ note: Notification) {
        guard
            let userInfo = note.userInfo,
            let conversationId = userInfo[RealtimeNotificationKey.conversationId] as? String,
            conversationId == conversation.id
        else { return }
        // Reload the chat snapshot from the local DB so local-only
        // mutations (view-once deletion tombstones, auto-vault
        // routing replacements) flip the on-screen bubble without
        // requiring a nav-away/return.
        Task {
            await viewModel.loadMessages(
                conversationId: conversation.id,
                messageRepository: container.messageRepository
            )
        }
    }

    private func handleRealtimeMessageReceived(_ note: Notification) {
        guard
            let userInfo = note.userInfo,
            let conversationId = userInfo[RealtimeNotificationKey.conversationId] as? String,
            conversationId == conversation.id,
            let message = userInfo[RealtimeNotificationKey.message] as? Message
        else { return }
        viewModel.handleRealtimeMessage(message)
        // Auto-mark incoming messages as read — repo gates receipts internally.
        Task {
            if conversation.type == .oneToOne {
                try? await container.messageRepository.markAsRead(
                    conversationId: conversation.id,
                    upToMessageId: message.id
                )
            } else {
                try? await container.messageRepository.markAsReadLocally(
                    conversationId: conversation.id,
                    upToMessageId: message.id
                )
            }
            NotificationCenter.default.postConversationStateDidChange(
                conversationId: conversation.id
            )
        }
    }

    private func handleRealtimeTypingChanged(_ note: Notification) {
        guard
            let userInfo = note.userInfo,
            let conversationId = userInfo[RealtimeNotificationKey.conversationId] as? String,
            conversationId == conversation.id,
            let typing = userInfo[RealtimeNotificationKey.typing] as? Sanchr_Messaging_TypingIndicator
        else { return }
        viewModel.handleTypingIndicator(typing)
    }

    private func handleRealtimeReceiptUpdated(_ note: Notification) {
        guard
            let userInfo = note.userInfo,
            let conversationId = userInfo[RealtimeNotificationKey.conversationId] as? String,
            conversationId == conversation.id,
            let receipt = userInfo[RealtimeNotificationKey.receipt] as? Sanchr_Messaging_ReceiptUpdate
        else { return }
        viewModel.handleReceipt(receipt)
    }

    private func handleRealtimePresenceUpdated(_ note: Notification) {
        guard
            let userInfo = note.userInfo,
            let presence = userInfo[RealtimeNotificationKey.presence] as? Sanchr_Messaging_PresenceUpdate
        else { return }
        viewModel.handlePresenceUpdate(presence, participantId: recipient?.id)
    }

    /// Sends the pending media after the caption screen is confirmed.
    /// Extracted to a method to keep the body modifier chain short enough
    /// for Swift's type checker.
    @MainActor
    private func commitPendingMediaSend(_ payload: PendingMediaSend, caption: String?) {
        pendingMediaSend = nil
        Task {
            await viewModel.sendMediaMessage(
                localFileURL: payload.localFileURL,
                mimeType: payload.mimeType,
                contentType: payload.contentType,
                conversationId: conversation.id,
                caption: caption,
                sessionService: container.sessionService,
                messageSender: container.messageSender
            )
        }
    }

    private func handleSelectedPhoto(_ item: PhotosPickerItem) async {
        let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })

        if isVideo {
            guard let videoData = try? await item.loadTransferable(type: Data.self) else { return }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try? videoData.write(to: tempURL)

            // Generate video thumbnail for optimistic UI
            let thumbnailURL = await generateVideoThumbnail(videoURL: tempURL)

            // Compute blur hash from thumbnail for instant receiver preview
            let videoBlurHash: String? = await Task.detached(priority: .utility) {
                guard let thumbURL = thumbnailURL,
                      let thumbImage = UIImage(contentsOfFile: thumbURL.path)
                else {
                    return nil
                }
                return BlurHash.encode(thumbImage)
            }.value

            var attachment = Message.MediaAttachment(
                url: thumbnailURL ?? tempURL, encryptionKey: Data(), encryptionIV: Data(),
                mimeType: "video/mp4", sizeBytes: Int64(videoData.count), thumbnailURL: thumbnailURL
            )
            attachment.blurHash = videoBlurHash

            // Show caption screen before sending — user can optionally add a caption.
            pendingMediaSend = PendingMediaSend(
                preview: .video(tempURL),
                localFileURL: tempURL,
                mimeType: "video/mp4",
                contentType: .video(attachment)
            )
        } else {
            guard let imageData = try? await item.loadTransferable(type: Data.self),
                  let sourceImage = UIImage(data: imageData) else { return }

            // Pre-compute blur hash on the original image so it survives editing.
            let imageBlurHash: String? = await Task.detached(priority: .utility) {
                BlurHash.encode(sourceImage)
            }.value

            // Open the image editor before showing the caption screen.
            pendingImageEdit = PendingImageEdit(image: sourceImage, blurHash: imageBlurHash)
        }
    }

    /// Called by the `ImageEditorView` completion handler with the edited `UIImage`.
    /// JPEG-encodes the result, writes it to a temp file, then routes it to
    /// the standard caption / send flow via `pendingMediaSend`.
    @MainActor
    private func commitImageEdit(_ editedImage: UIImage, blurHash: String?) async {
        guard let imageData = editedImage.jpegData(compressionQuality: 0.92) else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try? imageData.write(to: tempURL)

        var attachment = Message.MediaAttachment(
            url: tempURL, encryptionKey: Data(), encryptionIV: Data(),
            mimeType: "image/jpeg", sizeBytes: Int64(imageData.count), thumbnailURL: nil
        )
        attachment.blurHash = blurHash

        pendingMediaSend = PendingMediaSend(
            preview: .image(imageData),
            localFileURL: tempURL,
            mimeType: "image/jpeg",
            contentType: .image(attachment)
        )
    }
}
