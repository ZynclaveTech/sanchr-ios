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

/// Carries a staged multi-photo selection into the batch review screen.
private struct PendingBatchReview: Identifiable {
    let id = UUID()
    let items: [BatchMediaItem]
}

/// A staged item on its way from the picker to the review screen.
///
/// `BatchMediaItem` carries a `UIImage` thumbnail, which cannot cross the
/// concurrency boundary the task group introduces. Staging therefore hands
/// back JPEG bytes and the main actor decodes them — a few kilobytes each, so
/// the decode is cheap and the heavy work stays off the main thread where it
/// belongs.
private struct StagedMedia: Sendable {
    let kind: BatchMediaItem.Kind
    let fileURL: URL
    let sizeBytes: Int64
    let thumbnailJPEG: Data?
    var posterURL: URL? = nil
    let blurHash: String?
    let pixelWidth: Int?
    let pixelHeight: Int?

    @MainActor
    func item() -> BatchMediaItem {
        BatchMediaItem(
            kind: kind,
            fileURL: fileURL,
            sizeBytes: sizeBytes,
            thumbnail: thumbnailJPEG.flatMap(UIImage.init(data:)),
            posterURL: posterURL,
            blurHash: blurHash,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
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
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isInputFocused: Bool
    /// Which tray is showing below the composer, if any.
    ///
    /// One value rather than three booleans. As three, opening a tray meant
    /// remembering to close the other two at every call site — and the "+"
    /// button never closed the sticker tray, so opening stickers from the
    /// attachment sheet and then tapping "+" put both on screen at once.
    /// Mutual exclusion is the type's job now.
    @State private var activeTray: ComposerTray?
    @State private var showCameraCapture = false
    @State private var showPhotosPicker = false
    /// Separate from the photos picker so the sheet can offer a video-only
    /// choice. `Photos` already accepts video, but with a library full of
    /// stills finding a clip means scrolling past everything else.
    @State private var showVideoPicker = false
    @State private var selectedVideoItems: [PhotosPickerItem] = []
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
    @State private var pendingBatchReview: PendingBatchReview? = nil
    @State private var isStagingBatch = false
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

                // Restore whatever was left half-typed. Only when the composer
                // is still empty: a draft must never overwrite something the
                // user has already started typing in this session, which can
                // happen when this task resumes after a re-entry.
                if viewModel.inputText.isEmpty,
                    let draft = try? await container.localDatabase.draft(
                        conversationId: conversation.id
                    ),
                    !draft.isEmpty
                {
                    viewModel.inputText = draft
                }
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
                // Persist the unsent text. Saved here rather than per keystroke:
                // a draft only matters once the user has left, and writing to
                // the database on every character would be a write per
                // keypress for a value nobody reads until then.
                let draft = viewModel.inputText
                Task { [localDatabase = container.localDatabase, id = conversation.id] in
                    try? await localDatabase.saveDraft(conversationId: id, text: draft)
                }

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
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.userDidTakeScreenshotNotification)
            ) { _ in
                // Sanchr Mode: iOS can't block a screenshot, but it surfaces one
                // after the fact — mirror the view-once behaviour and notify the
                // peer so a screenshot of the conversation is never silent.
                guard container.privacySettings.sanchrModeEnabled else { return }
                let conversationId = conversation.id
                Task {
                    try? await container.messageRepository.sendSystemEvent(
                        .screenshotDetected, conversationId: conversationId)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // onDisappear does not fire when the app is backgrounded from
                // inside a chat, which is exactly when an unsent message is
                // most likely to be abandoned.
                guard phase != .active else { return }
                let draft = viewModel.inputText
                Task { [localDatabase = container.localDatabase, id = conversation.id] in
                    try? await localDatabase.saveDraft(conversationId: id, text: draft)
                }
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
                    if activeTray != nil {
                        withAnimation(.easeInOut(duration: 0.25)) { activeTray = nil }
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
                            messageSender: container.messageSender,
                            mediaCache: container.mediaDownloadManager
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

            // Send failures set `errorMessage` and nothing rendered it, so a
            // forward or a location send that failed reported nothing at all.
            // A failed message bubble has its own retry affordance; this is for
            // the failures that never become a bubble.
            if let error = viewModel.errorMessage {
                sendErrorBanner(error)
            }

            ChatInputBarView(
                conversation: conversation,
                input: viewModel.inputState,
                isInputFocused: $isInputFocused,
                voicePlayback: voicePlayback,
                activeTray: $activeTray,
                enterSendsMessage: enterSendsMessage,
                attachmentSendContext: { makeAttachmentSendContext() },
                onSendText: {
                    await viewModel.sendMessage(
                        conversationId: conversation.id,
                        sessionService: container.sessionService,
                        messageSender: container.messageSender
                    )
                    // The composer is empty again, so the stored draft is
                    // stale. Left alone, force-quitting after a send would
                    // restore text the user had already sent.
                    try? await container.localDatabase.saveDraft(
                        conversationId: conversation.id,
                        text: nil
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
                    await routeAttachmentIntent(intent, context: ctx)
                },
                onClearReply: { viewModel.clearReply() }
            )

            if activeTray == .attachments {
                AttachmentPickerHost(
                    onIntent: { intent in
                        let ctx = makeAttachmentSendContext()
                        Task { @MainActor in
                            await routeAttachmentIntent(intent, context: ctx)
                        }
                    },
                    onRequestAction: { item in
                        switch item {
                        case .camera:  closeTrayThen { showCameraCapture = true }
                        case .photos:  closeTrayThen { showPhotosPicker = true }
                        case .video:   closeTrayThen { showVideoPicker = true }
                        case .file:    closeTrayThen { showFileImporter = true }
                        case .contact: closeTrayThen { showContactPicker = true }

                        case .gif:
                            // Swapped, not closed and reopened. Routing this
                            // through `closeTrayThen` played the tray out and
                            // back in for what is a change of tab.
                            withAnimation(.easeInOut(duration: 0.25)) {
                                activeTray = .stickers
                            }

                        case .location:
                            closeTrayThen {
                                let ctx = makeAttachmentSendContext()
                                Task { @MainActor in
                                    // Bind to a local to keep the LocationSource
                                    // alive across the suspension; the
                                    // CLLocationManager's delegate is weak, so a
                                    // temporary would race ARC.
                                    let source = LocationSource()
                                    do {
                                        let payload = try await source.requestOneShot()
                                        await viewModel.send(intent: .location(payload), context: ctx)
                                    } catch {
                                        SanchrLogger.chat.error("Location request failed: \(error)")
                                        // Was logged and nothing more, so a
                                        // refused or unavailable location made
                                        // the pill look inert.
                                        viewModel.errorMessage = Self.locationFailureMessage(error)
                                    }
                                }
                            }
                        }
                    }
                )
                .frame(height: 280)
                .background(SanchrExportColors.background)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if activeTray == .emoji {
                EmojiPickerSheet { emoji in
                    viewModel.inputState.inputText.append(emoji)
                }
                .frame(height: 280)
                .background(SanchrExportColors.background)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if activeTray == .stickers {
                StickerPickerSheet(
                    onStickerSelected: { data in
                        let ctx = makeAttachmentSendContext()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            activeTray = nil
                        }
                        Task { @MainActor in
                            await viewModel.send(intent: .sticker(data), context: ctx)
                        }
                    },
                    onGIFSelected: { url in
                        let ctx = makeAttachmentSendContext()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            activeTray = nil
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
        .photosPicker(
            isPresented: $showVideoPicker,
            selection: $selectedVideoItems,
            maxSelectionCount: 10,
            matching: .videos
        )
        .onChange(of: selectedVideoItems) { _, items in
            guard !items.isEmpty else { return }
            let selected = items
            selectedVideoItems = []
            // Same routing as photos: one goes through the editor-and-caption
            // path, several through the batch review screen.
            Task {
                if selected.count == 1, let only = selected.first {
                    await handleSelectedPhoto(only)
                } else {
                    await stageBatchForReview(selected)
                }
            }
        }
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
        .fullScreenCover(item: $pendingBatchReview) { pending in
            MediaBatchReviewView(
                model: MediaBatchReviewModel(items: pending.items),
                onSend: { reviewed in
                    pendingBatchReview = nil
                    Task { await sendReviewedBatch(reviewed) }
                },
                onCancel: { pendingBatchReview = nil }
            )
        }
        // Copying a video out of the photo library takes real time, and an
        // iCloud-only clip has to be fetched first. `isStagingBatch` was
        // tracked but never rendered, so that whole wait looked like the tap
        // had simply done nothing.
        .overlay {
            if isStagingBatch {
                stagingIndicator
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
                // One photo keeps the single-photo editor. A batch goes to the
                // review screen, which owns its own editor and per-photo
                // captions — the per-photo editor cannot be chained here
                // because it is presented by assigning state and returning,
                // so looping it overwrites itself once per photo.
                if selectedItems.count == 1, let only = selectedItems.first {
                    await handleSelectedPhoto(only)
                } else {
                    await stageBatchForReview(selectedItems)
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

    /// Sits directly above the composer, where the failing action happened.
    ///
    /// Dismissible and self-clearing: an error about one send should not
    /// outlive the next one, and it must never become permanent furniture
    /// above the keyboard.
    private func sendErrorBanner(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.sanchrWarning)

            Text(error)
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { viewModel.errorMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SanchrExportColors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .task(id: error) {
            // Clears itself so it cannot sit above the composer forever.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { viewModel.errorMessage = nil }
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
        .onChange(of: isScrolledToBottom) { _, atBottom in
            // Returning to the newest end is the one moment the window can be
            // shrunk without risk: everything below is loaded, and what gets
            // dropped is exactly what paging up re-fetches.
            viewModel.trimToRecentWindowIfAtBottom(isAtBottom: atBottom)
        }
    }

    private static func generateVideoThumbnail(videoURL: URL) async -> URL? {
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
    /// Closes the tray, then does the thing once it has gone.
    ///
    /// Six copies of this sat inline, each pairing `activeTray = nil` with a
    /// hand-written `asyncAfter(0.25)` matching the animation's duration by
    /// eye. Changing the animation would have left six presentations racing a
    /// tray that was still on screen.
    private func closeTrayThen(_ action: @escaping () -> Void) {
        withAnimation(.easeInOut(duration: Self.trayDismissDuration)) {
            activeTray = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.trayDismissDuration) {
            action()
        }
    }

    private static let trayDismissDuration: TimeInterval = 0.25

    /// Location can fail for reasons the user can act on and reasons they
    /// cannot; saying which is the difference between a fixable refusal and an
    /// app that looks broken.
    static func locationFailureMessage(_ error: Error) -> String {
        switch error as? LocationSource.Error {
        case .denied:
            return "Sanchr doesn't have access to your location. You can turn it on in Settings."
        case .timeout:
            return "Couldn't get your location in time. Try again in a moment."
        case .failed(let reason):
            return "Couldn't get your location: \(reason)"
        case nil:
            return "Couldn't get your location. Try again in a moment."
        }
    }

    private func makeAttachmentSendContext() -> ChatDetailViewModel.AttachmentSendContext {
        ChatDetailViewModel.AttachmentSendContext(
            conversationId: conversation.id,
            recipientId: recipient?.id ?? "",
            sessionService: container.sessionService,
            messageSender: container.messageSender,
            vaultSharingCoordinator: container.vaultSharingCoordinator,
            mediaCache: container.mediaDownloadManager
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
                messageSender: container.messageSender,
                mediaCache: container.mediaDownloadManager
            )
        }
    }

    private func handleSelectedPhoto(_ item: PhotosPickerItem) async {
        let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })

        if isVideo {
            // Streamed to disk rather than read into memory; see PickedVideoFile.
            guard let video = try? await item.loadTransferable(type: PickedVideoFile.self) else {
                return
            }
            let tempURL = video.url
            let videoBytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size]
                as? NSNumber)??.int64Value ?? 0

            // Generate video thumbnail for optimistic UI
            let thumbnailURL = await Self.generateVideoThumbnail(videoURL: tempURL)

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
                // `url` is the media itself, not its poster. The send path
                // uploads whatever this points at, so pointing it at the
                // poster meant the clip was never uploaded at all: the
                // recipient received a 30 KB still labelled video/mp4, and
                // the player was handed a JPEG to play. The poster travels in
                // `thumbnailURL`, which is what it is for.
                url: tempURL, encryptionKey: Data(), encryptionIV: Data(),
                mimeType: "video/mp4", sizeBytes: videoBytes, thumbnailURL: thumbnailURL
            )
            attachment.blurHash = videoBlurHash
            // The poster frame is generated from the video, so it carries the
            // clip's aspect ratio — including any rotation already applied.
            if let thumbnailURL,
               let poster = UIImage(contentsOfFile: thumbnailURL.path) {
                attachment.width = Int(poster.size.width * poster.scale)
                attachment.height = Int(poster.size.height * poster.scale)
            }

            // Show caption screen before sending — user can optionally add a caption.
            pendingMediaSend = PendingMediaSend(
                preview: .video(tempURL),
                localFileURL: tempURL,
                mimeType: "video/mp4",
                contentType: .video(.init(attachment))
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
        // Pixel dimensions travel with the attachment so the receiver can size
        // the bubble before a single byte of the image has downloaded. Without
        // them every photo renders at a fixed 220x180 guess and then jumps to
        // its real shape once decoded.
        attachment.width = Int(editedImage.size.width * editedImage.scale)
        attachment.height = Int(editedImage.size.height * editedImage.scale)

        pendingMediaSend = PendingMediaSend(
            preview: .image(imageData),
            localFileURL: tempURL,
            mimeType: "image/jpeg",
            contentType: .image(.init(attachment))
        )
    }

    /// Stages a multi-photo selection on disk and opens the review screen.
    ///
    /// Full-size bytes go to temp files rather than being held in memory: a
    /// 30-photo batch would otherwise be well over a hundred megabytes. Only
    /// small thumbnails are retained for the filmstrip.
    ///
    /// Sends an attachment intent, diverting picked photos and videos to the
    /// review screen first.
    ///
    /// The attachment sheet emits `.photoLibrary` straight into the send
    /// pipeline, one message per item. That bypassed the review screen
    /// entirely — which is wired to the system photos picker — so a selection
    /// made in the sheet could not be captioned and had no single send step.
    /// Every other intent is passed straight through untouched.
    @MainActor
    private func routeAttachmentIntent(
        _ intent: AttachmentIntent,
        context: ChatDetailViewModel.AttachmentSendContext
    ) async {
        guard case .photoLibrary(let picked) = intent, !picked.isEmpty else {
            await viewModel.send(intent: intent, context: context)
            return
        }

        let staged = await stagePickedMediaForReview(picked)
        guard !staged.isEmpty else {
            // Nothing could be staged; fall back rather than dropping the send.
            await viewModel.send(intent: intent, context: context)
            return
        }
        pendingBatchReview = PendingBatchReview(items: staged)
    }

    /// Converts picker output into review items, writing the bytes to temp
    /// files so the screen holds only thumbnails.
    @MainActor
    private func stagePickedMediaForReview(_ picked: [PickedMedia]) async -> [BatchMediaItem] {
        var staged: [BatchMediaItem] = []
        for media in picked {
            switch media.kind {
            case .photo:
                guard let image = UIImage(data: media.data),
                      let jpeg = image.jpegData(compressionQuality: 0.92)
                else { continue }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).jpg")
                guard (try? jpeg.write(to: url)) != nil else { continue }

                let (blurHash, thumbnail) = await Task.detached(priority: .utility) {
                    (BlurHash.encode(image), BatchThumbnail.make(from: image))
                }.value
                staged.append(
                    BatchMediaItem(
                        kind: .photo,
                        fileURL: url,
                        sizeBytes: Int64(jpeg.count),
                        thumbnail: thumbnail,
                        blurHash: blurHash,
                        // The picker already measured these; they were simply
                        // being dropped on the way to the attachment.
                        pixelWidth: media.width > 0 ? media.width : nil,
                        pixelHeight: media.height > 0 ? media.height : nil
                    )
                )

            case .video:
                let stagedFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).mp4")
                if let source = media.fileURL {
                    guard (try? FileManager.default.copyItem(at: source, to: stagedFile)) != nil
                    else { continue }
                } else {
                    guard (try? media.data.write(to: stagedFile)) != nil else { continue }
                }
                // Not compressed here. Transcoding before the review screen
                // put a multi-second stall between tapping a video and seeing
                // it; `MessageSender` does it behind the upload bar instead.
                let url = stagedFile

                let posterURL = await Self.generateVideoThumbnail(videoURL: url)
                let poster = posterURL.flatMap { UIImage(contentsOfFile: $0.path) }
                let (blurHash, thumbnail) = await Task.detached(priority: .utility) {
                    (
                        poster.flatMap { BlurHash.encode($0) },
                        poster.flatMap { BatchThumbnail.make(from: $0) }
                    )
                }.value
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(media.data.count)

                staged.append(
                    BatchMediaItem(
                        kind: .video(durationSeconds: media.durationSeconds),
                        fileURL: url,
                        sizeBytes: size,
                        thumbnail: thumbnail,
                        posterURL: posterURL,
                        blurHash: blurHash,
                        pixelWidth: media.width > 0 ? media.width : nil,
                        pixelHeight: media.height > 0 ? media.height : nil
                    )
                )
            }
        }
        return staged
    }

    private var stagingIndicator: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Preparing…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .transition(.opacity)
        // The picker is dismissing behind this; swallow taps so a stray one
        // cannot reach the transcript underneath.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing media")
    }

    /// Photos and videos both go through the review screen. Videos are
    /// previewed with a player and cannot be sent through the still editor.
    ///
    /// Items stage concurrently. The loop that ran them one at a time made a
    /// multi-select cost the sum of every copy rather than the longest one,
    /// and nothing was shown until the last of them finished.
    @MainActor
    private func stageBatchForReview(_ pickerItems: [PhotosPickerItem]) async {
        withAnimation(.easeOut(duration: 0.15)) { isStagingBatch = true }
        defer { withAnimation(.easeOut(duration: 0.15)) { isStagingBatch = false } }

        let staged = await withTaskGroup(of: (Int, StagedMedia?).self) { group in
            for (index, pickerItem) in pickerItems.enumerated() {
                let isVideo = pickerItem.supportedContentTypes.contains { $0.conforms(to: .movie) }
                group.addTask {
                    let staged = isVideo
                        ? await Self.stageVideoForReview(pickerItem)
                        : await Self.stagePhotoForReview(pickerItem)
                    return (index, staged)
                }
            }
            // Completion order is arbitrary; the user picked an order and
            // expects to review it in that order.
            var collected: [(Int, StagedMedia)] = []
            for await (index, staged) in group {
                if let staged { collected.append((index, staged)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        guard !staged.isEmpty else { return }
        pendingBatchReview = PendingBatchReview(items: staged.map { $0.item() })
    }

    /// Decoding and re-encoding a full-resolution photo is work proportional
    /// to its pixel count, and it used to run on the main actor — stalling the
    /// very UI that is supposed to be showing progress meanwhile.
    private static func stagePhotoForReview(_ pickerItem: PhotosPickerItem) async -> StagedMedia? {
        guard let data = try? await pickerItem.loadTransferable(type: Data.self) else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> StagedMedia? in
            guard let image = UIImage(data: data) else { return nil }

            // Re-encode so HEIC from the camera roll reaches the recipient as
            // JPEG, matching the single-photo path.
            guard let jpeg = image.jpegData(compressionQuality: 0.92) else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).jpg")
            guard (try? jpeg.write(to: url)) != nil else { return nil }

            return StagedMedia(
                kind: .photo,
                fileURL: url,
                sizeBytes: Int64(jpeg.count),
                thumbnailJPEG: BatchThumbnail.make(from: image)?.jpegData(compressionQuality: 0.8),
                blurHash: BlurHash.encode(image),
                pixelWidth: Int(image.size.width * image.scale),
                pixelHeight: Int(image.size.height * image.scale)
            )
        }.value
    }

    /// The copy out of the photo library dominates here and cannot be avoided
    /// — the clip has to be on disk before a poster can be read from it, and
    /// an iCloud-only video has to be fetched first. What used to sit on top
    /// of it was a full transcode; that now happens on the send path instead.
    private static func stageVideoForReview(_ pickerItem: PhotosPickerItem) async -> StagedMedia? {
        // Streamed to disk rather than read into memory; see PickedVideoFile.
        guard let video = try? await pickerItem.loadTransferable(type: PickedVideoFile.self) else {
            return nil
        }
        let url = video.url

        // Poster frame doubles as the filmstrip thumbnail and as the
        // attachment's thumbnail for the recipient's bubble, the same way the
        // single-video path builds it.
        let posterURL = await Self.generateVideoThumbnail(videoURL: url)
        let duration = try? await AVURLAsset(url: url).load(.duration).seconds

        return await Task.detached(priority: .userInitiated) { () -> StagedMedia in
            let poster = posterURL.flatMap { UIImage(contentsOfFile: $0.path) }
            return StagedMedia(
                kind: .video(durationSeconds: duration),
                fileURL: url,
                sizeBytes: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                    as? NSNumber)??.int64Value ?? 0,
                thumbnailJPEG: poster
                    .flatMap { BatchThumbnail.make(from: $0) }?
                    .jpegData(compressionQuality: 0.8),
                posterURL: posterURL,
                blurHash: poster.flatMap { BlurHash.encode($0) },
                pixelWidth: poster.map { Int($0.size.width * $0.scale) },
                pixelHeight: poster.map { Int($0.size.height * $0.scale) }
            )
        }.value
    }

    /// Sends a reviewed batch.
    ///
    /// Photos and videos go as a single album message so the recipient gets one
    /// bubble and one notification, which is the whole point of reviewing them
    /// together. Captions are per-item in the review screen, so anything
    /// captioned individually is sent on its own — an album carries one caption
    /// and merging them would silently drop what the user typed.
    @MainActor
    private func sendReviewedBatch(_ items: [BatchMediaItem]) async {
        let captioned = items.filter {
            !$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let sendableAsAlbum = items.count > 1 && captioned.count <= 1

        if sendableAsAlbum {
            await sendAsAlbum(items)
        } else {
            for item in items { await sendSingle(item) }
        }
    }

    @MainActor
    private func sendAsAlbum(_ items: [BatchMediaItem]) async {
        let attachments = items.map { $0.sendableAttachment() }
        let caption = items
            .compactMap { $0.caption.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        // Routed through the view model so the bubble appears immediately.
        // Calling the sender directly wrote a database row but never touched
        // the in-memory transcript, so the album only surfaced after something
        // else reloaded it.
        await viewModel.sendAlbumMessage(
            attachments: attachments,
            caption: caption,
            conversationId: conversation.id,
            sessionService: container.sessionService,
            messageSender: container.messageSender,
            mediaCache: container.mediaDownloadManager
        )
    }

    @MainActor
    private func sendSingle(_ item: BatchMediaItem) async {
        let caption = item.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        await viewModel.sendMediaMessage(
            localFileURL: item.fileURL,
            mimeType: item.mimeType,
            contentType: item.kind.isVideo
                ? .video(.init(item.sendableAttachment()))
                : .image(.init(item.sendableAttachment())),
            conversationId: conversation.id,
            caption: caption.isEmpty ? nil : caption,
            sessionService: container.sessionService,
            messageSender: container.messageSender,
            mediaCache: container.mediaDownloadManager
        )
    }

}
