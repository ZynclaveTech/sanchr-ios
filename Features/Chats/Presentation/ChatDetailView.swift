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

    /// True while this contact's identity key has changed and the local user has
    /// not reviewed it. Sending is blocked by the identity store for as long as
    /// this holds, so the banner is the user's only route back to a working chat.
    @State private var hasUnreviewedIdentityChange = false
    @State private var showIdentityReview = false

    private func refreshIdentityChangeState() {
        guard let id = recipient?.id, !id.isEmpty else {
            hasUnreviewedIdentityChange = false
            return
        }
        hasUnreviewedIdentityChange = container.signalProtocol.hasPendingIdentityChange(userId: id)
    }

    /// Persistent warning shown when the contact's safety number changed.
    ///
    /// Deliberately not dismissible: it is the only indication that sends are
    /// failing closed, and it stays until the user either compares the new safety
    /// number (Verify) or explicitly accepts the change.
    @ViewBuilder
    private var identityChangeBanner: some View {
        if hasUnreviewedIdentityChange {
            let name = recipient?.displayName ?? "This contact"
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Security code changed")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "\(name)'s security code changed. This happens when they reinstall or switch devices — but it can also mean someone is intercepting this chat. Messages won't send until you review."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Button("Verify safety number") { showIdentityReview = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Accept change") {
                        if let id = recipient?.id, !id.isEmpty {
                            container.signalProtocol.acceptIdentityChange(userId: id)
                            refreshIdentityChangeState()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) {
                Divider().overlay(Color.orange.opacity(0.35))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Security code changed for \(name). Messages will not send until you review.")
        }
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
                    transcriptScrollSequence &+= 1
                    transcriptScrollCommand = .message(
                        id: firstUnreadId,
                        sequence: transcriptScrollSequence
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
            .onChange(of: viewModel.searchState.searchQuery) { _, query in
                viewModel.scheduleSearch(
                    conversationId: conversation.id,
                    query: query,
                    localDatabase: container.localDatabase
                )
            }
            .onChange(of: viewModel.searchState.currentSearchResultId) { _, messageId in
                guard let messageId else { return }
                transcriptScrollSequence &+= 1
                transcriptScrollCommand = .message(
                    id: messageId,
                    sequence: transcriptScrollSequence
                )
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

            identityChangeBanner

            if viewModel.searchState.isSearching {
                chatSearchBar
            }

            ZStack(alignment: .bottomTrailing) {
                ChatTranscriptView(
                    conversation: conversation,
                    messagesState: viewModel.messagesState,
                    voicePlayback: voicePlayback,
                    galleryCoordinator: galleryCoordinator,
                    contactCoordinator: contactCoordinator,
                    locationCoordinator: locationCoordinator,
                    documentCoordinator: documentCoordinator,
                    isScrolledToBottom: $isScrolledToBottom,
                    newMessageCountWhileScrolled: $newMessageCountWhileScrolled,
                    transcriptScrollSequence: $transcriptScrollSequence,
                    transcriptScrollCommand: $transcriptScrollCommand,
                    hasPresentedInitialTranscript: $hasPresentedInitialTranscript,
                    hasScheduledDeferredEntryTasks: $hasScheduledDeferredEntryTasks,
                    messageToForward: $messageToForward,
                    onReply: { viewModel.setReply(to: $0) },
                    onReact: { emoji, messageId in
                        viewModel.toggleReaction(
                            emoji: emoji,
                            messageId: messageId,
                            conversationId: conversation.id,
                            userId: container.signalProtocol.localUserId,
                            chatDataSource: container.chatDataSource
                        )
                    },
                    onDeleteMessage: { message in
                        Task {
                            // Local-only: deleting for everyone needs a
                            // confirmation step this menu does not present.
                            await viewModel.deleteMessage(
                                message,
                                forEveryone: false,
                                messageRepository: container.messageRepository,
                                chatDataSource: container.chatDataSource
                            )
                        }
                    },
                    onRetry: { message in
                        await viewModel.retryMessage(
                            message,
                            sessionService: container.sessionService,
                            messageSender: container.messageSender
                        )
                    },
                    onLoadMore: {
                        await viewModel.loadMore(
                            conversationId: conversation.id,
                            messageRepository: container.messageRepository
                        )
                    },
                    onRouteInteraction: { interaction in
                        viewModel.route(
                            interaction: interaction,
                            onOpenGallery: { galleryCoordinator.present(seed: $0) },
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
                    }
                )

                if !isScrolledToBottom {
                    scrollToBottomFAB
                }

                // Reaction picker overlay removed — reactions are in context menu
            }

            if viewModel.presenceState.showsTypingIndicators && (viewModel.presenceState.peerIsTyping || viewModel.presenceState.peerPresenceStatus == .typing) {
                typingPill
            }

            ChatInputBarView(
                conversation: conversation,
                input: viewModel.inputState,
                isInputFocused: $isInputFocused,
                voicePlayback: voicePlayback,
                showAttachmentPicker: $showAttachmentPicker,
                showEmojiPicker: $showEmojiPicker,
                enterSendsMessage: enterSendsMessage,
                attachmentSendContext: { makeAttachmentSendContext() },
                onSendText: {
                    await viewModel.sendMessage(
                        conversationId: conversation.id,
                        sessionService: container.sessionService,
                        messageSender: container.messageSender
                    )
                },
                onInputTextChanged: { newValue in
                    viewModel.handleInputTextChanged(
                        newValue,
                        conversationId: conversation.id,
                        messageRepository: container.messageRepository
                    )
                },
                onSendIntent: { intent, ctx in
                    await viewModel.send(intent: intent, context: ctx)
                },
                onClearReply: { viewModel.clearReply() }
            )

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
                    viewModel.inputState.inputText.append(emoji)
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
        .task { refreshIdentityChangeState() }
        .onReceive(NotificationCenter.default.publisher(for: .sanchrIdentityChangeStateDidChange)) {
            _ in
            refreshIdentityChangeState()
        }
        .sheet(isPresented: $showIdentityReview, onDismiss: { refreshIdentityChangeState() }) {
            NavigationStack {
                VerifySecurityCodeView(conversation: conversation)
            }
        }
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
                messageLookup: { [vm] id in
                    vm.message(withId: id)
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
            presence: viewModel.presenceState,
            search: viewModel.searchState,
            isConversationArchived: $isConversationArchived,
            conversationActionErrorMessage: $conversationActionErrorMessage,
            showConversationInfo: $showConversationInfo,
            callErrorMessage: $callErrorMessage,
            onDismiss: { dismiss() },
            onConfigurePeer: { showsPresence, showsTyping in
                viewModel.configurePeer(
                    recipient,
                    showsPresence: showsPresence,
                    showsTypingIndicators: showsTyping
                )
            },
            onClearSearch: { viewModel.clearSearch() }
        )
    }

    private var chatSearchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)

                TextField("Search messages...", text: Bindable(viewModel.searchState).searchQuery)
                    .font(SanchrTypography.messageBubbleText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.scheduleSearch(
                            conversationId: conversation.id,
                            query: viewModel.searchState.searchQuery,
                            localDatabase: container.localDatabase
                        )
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .modifier(ChatSearchFieldSurfaceModifier())

            if !viewModel.searchState.searchResults.isEmpty {
                SanchrGlassCluster(spacing: 10) {
                    HStack(spacing: 6) {
                        Group {
                            if #available(iOS 26.0, *) {
                                Text("\(viewModel.searchState.currentSearchIndex + 1)/\(viewModel.searchState.searchResults.count)")
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 32)
                                    .sanchrGlass(role: .chip)
                            } else {
                                Text("\(viewModel.searchState.currentSearchIndex + 1)/\(viewModel.searchState.searchResults.count)")
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
                    viewModel.searchState.isSearching = false
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

    private var scrollToBottomFAB: some View {
        Button {
            newMessageCountWhileScrolled = 0
            transcriptScrollSequence &+= 1
            transcriptScrollCommand = .manualBottom(sequence: transcriptScrollSequence)
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
