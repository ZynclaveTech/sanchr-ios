import AVFoundation
import ImageIO
import Kingfisher
import PhotosUI
import SwiftUI

struct ChatDetailView: View {
    let conversation: Conversation

    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ChatDetailViewModel()
    @FocusState private var isInputFocused: Bool
    @State private var showAttachmentPicker = false
    @State private var showCameraCapture = false
    @State private var showEmojiPicker = false
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

    private var recipient: User? {
        conversation.participants.first(where: { !$0.isLocalUser })
    }

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
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
                                    print("[AttachmentPicker] location failed: \(error)")
                                }
                            }
                        }
                    }
                )
                .frame(height: 240)
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
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
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
                        print("[AttachmentPicker] file import failed: \(error)")
                    }
                }
            case .failure(let error):
                print("[AttachmentPicker] file picker error: \(error)")
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
        .task {
            await viewModel.loadMessages(
                conversationId: conversation.id,
                messageRepository: container.messageRepository
            )
        }
        .onAppear {
            viewModel.configurePeer(recipient)
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
                    messageRepository: container.messageRepository,
                    canSend: container.privacySettings.canSendTypingIndicators
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimeMessageReceived)) { note in
            guard
                let userInfo = note.userInfo,
                let conversationId = userInfo[RealtimeNotificationKey.conversationId] as? String,
                conversationId == conversation.id,
                let message = userInfo[RealtimeNotificationKey.message] as? Message
            else {
                return
            }

            viewModel.handleRealtimeMessage(message)

            // Auto-mark incoming messages as read — gate receipt sending on privacy setting
            Task {
                if container.privacySettings.canSendReadReceipts {
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
        .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimeTypingChanged)) { note in
            guard
                let userInfo = note.userInfo,
                let conversationId = userInfo[RealtimeNotificationKey.conversationId] as? String,
                conversationId == conversation.id,
                let typing = userInfo[RealtimeNotificationKey.typing] as? Vync_Messaging_TypingIndicator
            else {
                return
            }

            viewModel.handleTypingIndicator(typing)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimeReceiptUpdated)) { note in
            guard
                let userInfo = note.userInfo,
                let conversationId = userInfo[RealtimeNotificationKey.conversationId] as? String,
                conversationId == conversation.id,
                let receipt = userInfo[RealtimeNotificationKey.receipt] as? Vync_Messaging_ReceiptUpdate
            else {
                return
            }

            viewModel.handleReceipt(receipt)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimePresenceUpdated)) { note in
            guard
                let userInfo = note.userInfo,
                let presence = userInfo[RealtimeNotificationKey.presence] as? Vync_Messaging_PresenceUpdate
            else {
                return
            }

            viewModel.handlePresenceUpdate(presence, participantId: recipient?.id)
        }
        .onChange(of: viewModel.inputText) { _, newValue in
            viewModel.handleInputTextChanged(
                newValue,
                conversationId: conversation.id,
                messageRepository: container.messageRepository,
                canSend: container.privacySettings.canSendTypingIndicators
            )
        }
        .onChange(of: isInputFocused) { _, focused in
            if !focused {
                // Keyboard dismissed — stop typing indicator
                Task {
                    await viewModel.stopTypingIndicator(
                        conversationId: conversation.id,
                        messageRepository: container.messageRepository,
                        canSend: container.privacySettings.canSendTypingIndicators
                    )
                }
            } else {
                // Keyboard appeared — mutually exclusive with attachment & emoji trays
                if showAttachmentPicker || showEmojiPicker {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showAttachmentPicker = false
                        showEmojiPicker = false
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

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.sanchrPrimary)
                }
                .buttonStyle(.plain)

                chatHeaderAvatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayName)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .lineLimit(1)

                    Text(headerStatusText)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if let recipient {
                        headerActionButton(icon: "video.fill") {
                            Task {
                                try? await container.startCallUseCase.execute(
                                    recipientId: recipient.id,
                                    recipientName: recipient.displayName,
                                    isVideo: true
                                )
                            }
                        }

                        headerActionButton(icon: "phone.fill") {
                            Task {
                                try? await container.startCallUseCase.execute(
                                    recipientId: recipient.id,
                                    recipientName: recipient.displayName,
                                    isVideo: false
                                )
                            }
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.isSearching.toggle()
                            if !viewModel.isSearching {
                                viewModel.clearSearch()
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .frame(width: SanchrSpacing.chatHeaderActionSize, height: SanchrSpacing.chatHeaderActionSize)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showConversationInfo = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .frame(width: SanchrSpacing.chatHeaderActionSize, height: SanchrSpacing.chatHeaderActionSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(SanchrColors.accent)
                Text("Messages are end-to-end encrypted")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [SanchrColors.e2eBannerStartLight, SanchrColors.e2eBannerEndLight],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(SanchrColors.e2eBannerBorder)
                    .frame(height: 1)
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea(edges: .top))
    }

    private var chatHeaderAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let avatarURL = conversation.avatarURL {
                    KFImage(avatarURL)
                        .resizable()
                        .placeholder {
                            Text(conversation.displayName.prefix(1).uppercased())
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(.sanchrPrimary)
                        }
                        .fade(duration: 0.2)
                        .scaledToFill()
                } else {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [SanchrColors.primary.opacity(0.2), SanchrColors.accent.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Text(conversation.displayName.prefix(1).uppercased())
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(.sanchrPrimary)
                        }
                }
            }
            .frame(width: SanchrSpacing.chatHeaderAvatarSize, height: SanchrSpacing.chatHeaderAvatarSize)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)

            if let recipient, recipient.status == .online || recipient.status == .typing {
                Circle()
                    .fill(SanchrColors.statusOnline)
                    .frame(width: SanchrSpacing.chatHeaderStatusDot, height: SanchrSpacing.chatHeaderStatusDot)
                    .overlay {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    }
                    .offset(x: 1, y: 1)
            }
        }
    }

    private func headerActionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SanchrExportColors.textSecondary)
                .frame(width: SanchrSpacing.chatHeaderActionSize, height: SanchrSpacing.chatHeaderActionSize)
        }
        .buttonStyle(.plain)
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
            .background(SanchrExportColors.surfaceSoft)
            .clipShape(Capsule())

            if !viewModel.searchResults.isEmpty {
                HStack(spacing: 4) {
                    Text("\(viewModel.currentSearchIndex + 1)/\(viewModel.searchResults.count)")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .frame(minWidth: 30)

                    Button { viewModel.previousSearchResult() } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Button { viewModel.nextSearchResult() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .buttonStyle(.plain)
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
                    userId: userId
                )
            },
            onLoadMore: {
                Task {
                    await viewModel.loadMore(
                        conversationId: conversation.id,
                        messageRepository: container.messageRepository
                    )
                }
            },
            isScrolledToBottom: $isScrolledToBottom,
            newMessageCountWhileScrolled: $newMessageCountWhileScrolled
        )
        .background(SanchrExportColors.surfaceSoft)
        .overlay {
            if !hasPresentedInitialTranscript {
                transcriptLoadingPlaceholder
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

    private var scrollToBottomFAB: some View {
        Button {
            newMessageCountWhileScrolled = 0
            issueTranscriptScroll(to: .manualBottom(sequence: nextTranscriptScrollSequence()))
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(SanchrExportColors.surface)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)

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

    private func dateSeparator(_ label: String) -> some View {
        HStack {
            Spacer()
            Text(label)
                .font(SanchrTypography.captionSmall)
                .fontWeight(.medium)
                .foregroundColor(SanchrExportColors.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(SanchrExportColors.surface)
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
                .overlay {
                    Capsule()
                        .stroke(SanchrExportColors.line, lineWidth: 1)
                }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func messageContextMenu(_ message: Message) -> some View {
        if case .text(let text) = message.content {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }

        Button {
            viewModel.setReply(to: message)
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }

        Button {
        } label: {
            Label("Forward", systemImage: "arrowshape.turn.up.right")
        }

        if message.isOutgoing {
            Divider()

            Button(role: .destructive) {
                Task {
                    await viewModel.deleteMessage(
                        message,
                        forEveryone: true,
                        messageRepository: container.messageRepository,
                        chatDataSource: container.chatDataSource
                    )
                }
            } label: {
                Label("Delete for Everyone", systemImage: "trash")
            }
        }

        Button(role: .destructive) {
            Task {
                await viewModel.deleteMessage(
                    message,
                    forEveryone: false,
                    messageRepository: container.messageRepository,
                    chatDataSource: container.chatDataSource
                )
            }
        } label: {
            Label("Delete for Me", systemImage: "trash")
        }
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
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(SanchrExportColors.textTertiary)
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
                    Image(systemName: showAttachmentPicker ? "xmark" : "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(SanchrColors.primary)
                        .frame(width: 36, height: 36)
                        .background(SanchrColors.primary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                // Text input field
                HStack(spacing: 6) {
                    TextField("Message...", text: $viewModel.inputText, axis: .vertical)
                        .font(SanchrTypography.messageBubbleText)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isInputFocused)

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
                                recipientId: recipient?.id ?? "",
                                messageRepository: container.messageRepository,
                                signalProtocol: container.signalProtocol,
                                chatDataSource: container.chatDataSource,
                                localDatabase: container.localDatabase,
                                sessionService: container.sessionService
                            )
                        }
                    } label: {
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
            scrollCommand: transcriptScrollCommand
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

        Task {
            if let recipient {
                container.realtimeService.trackPresencePeer(recipient.id)
            }

            async let preferencesLoad: Void = loadHeaderPreferences()
            async let readMark: Void = markConversationAsReadIfNeeded()
            _ = await (preferencesLoad, readMark)
        }
    }

    private func markConversationAsReadIfNeeded() async {
        guard let lastMessageId = viewModel.messages.last?.id else { return }

        if container.privacySettings.canSendReadReceipts {
            try? await container.messageRepository.markAsRead(
                conversationId: conversation.id,
                upToMessageId: lastMessageId
            )
        } else {
            try? await container.messageRepository.markAsReadLocally(
                conversationId: conversation.id,
                upToMessageId: lastMessageId
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

    private var headerStatusText: String {
        if viewModel.showsTypingIndicators, (viewModel.peerIsTyping || viewModel.peerPresenceStatus == .typing) {
            return "Typing..."
        }

        if viewModel.showsPresence, !viewModel.peerPresenceHidden, conversation.type == .oneToOne {
            if viewModel.peerPresenceStatus == .online {
                return "Online now"
            }

            if let lastSeen = viewModel.peerLastSeen {
                return "Last seen \(lastSeen.relativePresenceDescription)"
            }
        }

        if let phone = recipient?.phoneNumber, !phone.isEmpty {
            return phone
        }

        return "Encrypted conversation"
    }

    private func loadHeaderPreferences() async {
        do {
            let settings = try await settingsDataSource.getSettings()
            viewModel.configurePeer(
                recipient,
                showsPresence: settings.onlineStatusVisible,
                showsTypingIndicators: settings.typingIndicator
            )
        } catch {
            SanchrLogger.chat.error("Failed to load chat header preferences: \(error.localizedDescription)")
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
            messageRepository: container.messageRepository,
            signalProtocol: container.signalProtocol,
            chatDataSource: container.chatDataSource,
            localDatabase: container.localDatabase,
            sessionService: container.sessionService,
            mediaUploadManager: container.mediaUploadManager,
            mediaEncryption: container.mediaEncryption
        )
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

            await viewModel.sendMediaMessage(
                localFileURL: tempURL,
                mimeType: "video/mp4",
                contentType: .video(attachment),
                conversationId: conversation.id,
                recipientId: recipient?.id ?? "",
                caption: nil,
                messageRepository: container.messageRepository,
                signalProtocol: container.signalProtocol,
                chatDataSource: container.chatDataSource,
                localDatabase: container.localDatabase,
                sessionService: container.sessionService,
                mediaUploadManager: container.mediaUploadManager,
                mediaEncryption: container.mediaEncryption
            )
        } else {
            guard let imageData = try? await item.loadTransferable(type: Data.self) else { return }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try? imageData.write(to: tempURL)

            let imageBlurHash: String? = await Task.detached(priority: .utility) {
                UIImage(data: imageData).flatMap { BlurHash.encode($0) }
            }.value

            var attachment = Message.MediaAttachment(
                url: tempURL, encryptionKey: Data(), encryptionIV: Data(),
                mimeType: "image/jpeg", sizeBytes: Int64(imageData.count), thumbnailURL: nil
            )
            attachment.blurHash = imageBlurHash

            await viewModel.sendMediaMessage(
                localFileURL: tempURL,
                mimeType: "image/jpeg",
                contentType: .image(attachment),
                conversationId: conversation.id,
                recipientId: recipient?.id ?? "",
                caption: nil,
                messageRepository: container.messageRepository,
                signalProtocol: container.signalProtocol,
                chatDataSource: container.chatDataSource,
                localDatabase: container.localDatabase,
                sessionService: container.sessionService,
                mediaUploadManager: container.mediaUploadManager,
                mediaEncryption: container.mediaEncryption
            )
        }
    }
}

struct MessageBubble: View {
    let message: Message
    var uploadProgress: Double?
    var uploadLabel: String?
    var hideTimestamp: Bool = false
    var isGroupedWithPrev: Bool = false
    var isGroupedWithNext: Bool = false
    var voicePlayback: VoicePlaybackController

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        if case .system(let event) = message.content {
            // Centered system event pill
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SanchrColors.securityEventIcon)
                    Text(systemEventLabel(event))
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.medium)
                        .foregroundColor(SanchrColors.securityEventText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(SanchrColors.securityEventBg)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(SanchrColors.securityEventBorder, lineWidth: 1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .bottom) {
                if message.isOutgoing { Spacer(minLength: 0) }

                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
                    if message.replyToMessageId != nil {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(message.isOutgoing ? Color.white.opacity(0.5) : SanchrColors.primary)
                                .frame(width: 3)

                            Text("Replied to a message")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(message.isOutgoing ? Color.white.opacity(0.7) : SanchrExportColors.textSecondary)
                        }
                        .padding(.bottom, 4)
                    }

                    messageContent
                        .padding(.horizontal, SanchrSpacing.bubbleHPadding)
                        .padding(.vertical, SanchrSpacing.bubbleVPadding)
                        .background(bubbleBackground)
                        .clipShape(bubbleShape)
                        .shadow(
                            color: message.isOutgoing
                                ? Color.black.opacity(0.1)
                                : Color.black.opacity(0.04),
                            radius: message.isOutgoing ? 6 : 3,
                            x: 0,
                            y: message.isOutgoing ? 2 : 1
                        )
                        .overlay {
                            if !message.isOutgoing {
                                bubbleShape
                                    .stroke(SanchrExportColors.line, lineWidth: 1)
                            }
                        }

                    if !hideTimestamp {
                        timestampRow
                            .padding(.top, 4)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: UIScreen.main.bounds.width * SanchrSpacing.messageMaxWidthFraction, alignment: message.isOutgoing ? .trailing : .leading)

                if !message.isOutgoing { Spacer(minLength: 0) }
            }
        }
    }

    private func systemEventLabel(_ event: Message.SystemEvent) -> String {
        switch event {
        case .identityKeyChanged: return "Security code changed"
        case .disappearingTimerChanged: return "Disappearing timer changed"
        case .groupCreated: return "Group created"
        case .memberAdded: return "Member added"
        case .memberRemoved: return "Member removed"
        case .screenshotDetected: return "Screenshot detected"
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .text(let text):
            if let fallback = AttachmentFallbackParser.parse(text) {
                switch fallback {
                case .contact(let name):
                    contactFallbackBubble(name: name)
                case .location(let lat, let lng):
                    locationFallbackBubble(latitude: lat, longitude: lng)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(messageTextColor)
                        .multilineTextAlignment(.leading)

                    if let url = LinkPreviewService.firstURL(in: text) {
                        LinkPreviewCard(url: url, isOutgoing: message.isOutgoing)
                    }
                }
            }

        case .image(let attachment):
            MediaBubbleImage(attachment: attachment, messageId: message.id, isOutgoing: message.isOutgoing, uploadProgress: uploadProgress, uploadLabel: uploadLabel)

        case .video(let attachment):
            MediaBubbleImage(attachment: attachment, messageId: message.id, isOutgoing: message.isOutgoing, uploadProgress: uploadProgress, uploadLabel: uploadLabel)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 4)
                }

        case .audio(let attachment):
            if attachment.isVoiceMessage == true,
               let durationMs = attachment.audioDurationMs {
                VoicePlaybackBubble(
                    messageId: message.id,
                    url: attachment.url,
                    durationMs: durationMs,
                    waveform: attachment.audioWaveform ?? [],
                    playback: voicePlayback
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20))
                        .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
                    Text(formatDuration(attachment.durationSeconds ?? 0))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(messageTextColor)
                }
            }

        case .document(let attachment):
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename ?? attachment.url.lastPathComponent)
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.semibold)
                        .foregroundColor(messageTextColor)
                        .lineLimit(1)
                    Text(formatFileSize(attachment.sizeBytes))
                        .font(SanchrTypography.micro)
                        .foregroundColor(messageTextColor.opacity(0.7))
                }
            }

        default:
            Text("[Unsupported content]")
                .font(SanchrTypography.caption)
                .foregroundColor(messageTextColor.opacity(0.72))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        Self.fileSizeFormatter.string(fromByteCount: bytes)
    }

    @ViewBuilder
    private func contactFallbackBubble(name: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
                    .foregroundColor(messageTextColor)
                    .lineLimit(2)
                Text("Contact")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(messageTextColor.opacity(0.7))
            }
        }
    }

    /// Privacy contract: this view MUST NOT use MapKit, MKMapView,
    /// MKMapSnapshotter, CLGeocoder, or any reverse-geocoding API. The
    /// receiver only ever sees the raw lat/lng numbers, never a place name.
    @ViewBuilder
    private func locationFallbackBubble(latitude: Double, longitude: Double) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 28))
                .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Location")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
                    .foregroundColor(messageTextColor)
                Text("\(String(format: "%.4f", latitude)), \(String(format: "%.4f", longitude))")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(messageTextColor.opacity(0.7))
            }
        }
    }

    private var timestampRow: some View {
        HStack(spacing: 4) {
            Text(message.timestamp.messageTime)
                .font(SanchrTypography.messageTimestamp)
                .foregroundColor(SanchrExportColors.textTertiary)

            if message.isOutgoing {
                if isDoubleCheck {
                    ZStack(alignment: .leading) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .medium))
                            .offset(x: 5)
                    }
                    .foregroundColor(
                        message.status == .read
                            ? SanchrColors.accent
                            : SanchrExportColors.textTertiary
                    )
                    .frame(width: 16)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
            }
        }
    }

    private var bubbleBackground: some View {
        Group {
            if message.isOutgoing {
                LinearGradient(
                    colors: [SanchrColors.primary, SanchrColors.primaryDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                SanchrExportColors.surface
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let main = SanchrSpacing.bubbleMainRadius
        let tail = SanchrSpacing.bubbleTailRadius
        // Signal-style: sharp inner corners on the tail side when messages are clustered
        let sharp: CGFloat = 4
        if message.isOutgoing {
            // Tail is on the trailing side
            return UnevenRoundedRectangle(
                topLeadingRadius: main,
                bottomLeadingRadius: main,
                bottomTrailingRadius: isGroupedWithNext ? sharp : tail,
                topTrailingRadius: isGroupedWithPrev ? sharp : main
            )
        }
        // Tail is on the leading side
        return UnevenRoundedRectangle(
            topLeadingRadius: isGroupedWithPrev ? sharp : main,
            bottomLeadingRadius: isGroupedWithNext ? sharp : tail,
            bottomTrailingRadius: main,
            topTrailingRadius: main
        )
    }

    private var messageTextColor: Color {
        message.isOutgoing ? .white : SanchrExportColors.textPrimary
    }

    private var statusIcon: String {
        switch message.status {
        case .sending:
            return "clock"
        case .sent, .delivered:
            return "checkmark"
        case .read:
            return "checkmark"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    /// Whether to show double-check (delivered/read) vs single-check (sent).
    private var isDoubleCheck: Bool {
        message.status == .delivered || message.status == .read
    }
}

private struct MediaBubbleImage: View {
    let attachment: Message.MediaAttachment
    let messageId: String
    let isOutgoing: Bool
    var uploadProgress: Double?
    var uploadLabel: String?
    @Environment(DependencyContainer.self) private var container
    @State private var resolvedImage: UIImage?
    @State private var placeholderImage: UIImage?
    @State private var isDownloading = false

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB
        return cache
    }()

    private static let thumbCacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MediaMessages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var thumbCachePath: URL {
        Self.thumbCacheDir.appendingPathComponent("\(messageId)_thumb.jpg")
    }

    private static func cacheImage(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        imageCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private var cachedMediaFilePath: URL? {
        let ext: String
        if attachment.mimeType.contains("png") {
            ext = "png"
        } else if attachment.mimeType.hasPrefix("video/") {
            return nil
        } else {
            ext = "jpg"
        }
        let filePath = Self.thumbCacheDir.appendingPathComponent("\(messageId).\(ext)")
        return FileManager.default.fileExists(atPath: filePath.path) ? filePath : nil
    }

    private var displaySize: CGSize {
        BubbleMediaLayout.displaySize(for: attachment)
    }

    private var mediaLoadKey: String {
        [
            messageId,
            attachment.url.absoluteString,
            attachment.thumbnailURL?.absoluteString ?? "",
            attachment.mimeType,
            attachment.blurHash ?? "",
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            if let image = resolvedImage ?? placeholderImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if let progress = uploadProgress, resolvedImage != nil {
                            progressOverlay(progress: progress)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOutgoing ? Color.white.opacity(0.15) : SanchrExportColors.surfaceSoft)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay {
                        if isDownloading || uploadProgress != nil {
                            VStack(spacing: 6) {
                                ProgressView()
                                    .tint(isOutgoing ? .white : .sanchrPrimary)
                                if let label = uploadLabel {
                                    Text(label)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(isOutgoing ? .white.opacity(0.7) : SanchrExportColors.textTertiary)
                                }
                            }
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundColor(isOutgoing ? .white.opacity(0.5) : SanchrExportColors.textTertiary)
                        }
                    }
            }
        }
        .task(id: mediaLoadKey) {
            await loadImages()
        }
    }

    private func loadImages() async {
        if let cached = Self.imageCache.object(forKey: messageId as NSString) {
            resolvedImage = cached
            return
        }

        if placeholderImage == nil, let blurHash = attachment.blurHash {
            let targetSize = displaySize
            placeholderImage = await Task.detached(priority: .utility) {
                BubbleImagePipeline.decodeBlurHash(blurHash, size: targetSize)
            }.value
        }

        isDownloading = true
        defer { isDownloading = false }

        if let image = await loadResolvedImage() {
            Self.cacheImage(image, forKey: messageId)
            resolvedImage = image
        }
    }

    private func loadResolvedImage() async -> UIImage? {
        let scale = await MainActor.run { UIScreen.main.scale }
        let targetSize = displaySize

        if attachment.mimeType.hasPrefix("video/") {
            return await loadResolvedVideoThumbnail(scale: scale, targetSize: targetSize)
        }

        if let localURL = localImageCandidateURL() {
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: localURL,
                    to: targetSize,
                    scale: scale
                )
            }.value
        }

        let ext = mediaCacheExtension
        if let cached = await container.mediaDownloadManager.cachedURL(for: messageId, ext: ext) {
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: cached,
                    to: targetSize,
                    scale: scale
                )
            }.value
        }

        do {
            let url = try await container.mediaDownloadManager.download(
                messageId: messageId,
                attachment: attachment
            )
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: url,
                    to: targetSize,
                    scale: scale
                )
            }.value
        } catch {
            SanchrLogger.media.error("Media download failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadResolvedVideoThumbnail(scale: CGFloat, targetSize: CGSize) async -> UIImage? {
        if let thumbURL = localVideoThumbnailCandidateURL() {
            return await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    at: thumbURL,
                    to: targetSize,
                    scale: scale
                )
            }.value
        }

        let ext = mediaCacheExtension
        let cachedVideoURL: URL?
        if let cached = await container.mediaDownloadManager.cachedURL(for: messageId, ext: ext) {
            cachedVideoURL = cached
        } else {
            do {
                cachedVideoURL = try await container.mediaDownloadManager.download(
                    messageId: messageId,
                    attachment: attachment
                )
            } catch {
                SanchrLogger.media.error("Media download failed: \(error.localizedDescription)")
                return nil
            }
        }

        guard let cachedVideoURL else { return nil }
        return await generateAndCacheThumb(from: cachedVideoURL, scale: scale, targetSize: targetSize)
    }

    private func localImageCandidateURL() -> URL? {
        if attachment.url.isFileURL {
            return attachment.url
        }
        return cachedMediaFilePath
    }

    private func localVideoThumbnailCandidateURL() -> URL? {
        if let thumbnailURL = attachment.thumbnailURL, FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }
        if FileManager.default.fileExists(atPath: thumbCachePath.path) {
            return thumbCachePath
        }
        return nil
    }

    private var mediaCacheExtension: String {
        if attachment.mimeType.contains("png") {
            return "png"
        }
        if attachment.mimeType.hasPrefix("video/") {
            return attachment.mimeType.contains("quicktime") ? "mov" : "mp4"
        }
        return "jpg"
    }

    private func generateAndCacheThumb(from videoURL: URL, scale: CGFloat, targetSize: CGSize) async -> UIImage? {
        let destinationPath = thumbCachePath
        let thumbnail: UIImage? = await Task.detached(priority: .utility) {
            let asset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: targetSize.width * scale,
                height: targetSize.height * scale
            )
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil as UIImage?
            }

            let image = UIImage(cgImage: cgImage)
            if let jpegData = image.jpegData(compressionQuality: 0.7) {
                try? jpegData.write(to: destinationPath, options: .atomic)
            }
            return image
        }.value

        return thumbnail
    }

    private func progressOverlay(progress: Double) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)

            if let label = uploadLabel {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct LinkPreviewCard: View {
    let url: URL
    let isOutgoing: Bool
    @State private var preview: LinkPreviewData?
    @State private var previewImage: UIImage?
    @State private var isLoading = true

    private static let imageCache = NSCache<NSString, UIImage>()
    private let cardWidth: CGFloat = 220
    private let imageHeight: CGFloat = 120

    var body: some View {
        Group {
            if let preview {
                VStack(alignment: .leading, spacing: 0) {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: imageHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else if preview.imageData != nil {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill((isOutgoing ? Color.white : SanchrExportColors.textPrimary).opacity(0.08))
                            .frame(height: imageHeight)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let title = preview.title, !title.isEmpty {
                            Text(title)
                                .font(SanchrTypography.captionSmall)
                                .fontWeight(.semibold)
                                .foregroundColor(isOutgoing ? Color.white : SanchrExportColors.textPrimary)
                                .lineLimit(2)
                        }

                        Text(preview.domain)
                            .font(SanchrTypography.micro)
                            .foregroundColor(isOutgoing ? Color.white.opacity(0.7) : SanchrExportColors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(
                    isOutgoing
                        ? Color.white.opacity(0.1)
                        : SanchrExportColors.surfaceSoft
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(width: cardWidth, alignment: .leading)
                .onTapGesture {
                    UIApplication.shared.open(url)
                }
            } else if isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((isOutgoing ? Color.white : SanchrExportColors.textPrimary).opacity(0.08))
                        .frame(height: imageHeight)

                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(isOutgoing ? .white : Color.sanchrPrimary)
                        Text(url.host ?? "Loading...")
                            .font(SanchrTypography.micro)
                            .foregroundColor(isOutgoing ? Color.white.opacity(0.6) : SanchrExportColors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(
                    isOutgoing
                        ? Color.white.opacity(0.1)
                        : SanchrExportColors.surfaceSoft
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .task(id: url) {
            let cachedImage = Self.imageCache.object(forKey: url.absoluteString as NSString)
            if let cachedImage {
                previewImage = cachedImage
            }

            let preview = await LinkPreviewService.shared.preview(for: url)
            self.preview = preview
            self.isLoading = false

            guard let preview, let imageData = preview.imageData, previewImage == nil else { return }

            let scale = await MainActor.run { UIScreen.main.scale }
            let targetSize = CGSize(width: cardWidth, height: imageHeight)
            let decodedImage = await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    data: imageData,
                    to: targetSize,
                    scale: scale
                )
            }.value

            if let decodedImage {
                Self.imageCache.setObject(decodedImage, forKey: url.absoluteString as NSString)
                previewImage = decodedImage
            }
        }
    }
}

private enum BubbleMediaLayout {
    static let maxWidth: CGFloat = 220
    static let maxHeight: CGFloat = 280

    static func displaySize(for attachment: Message.MediaAttachment) -> CGSize {
        guard let width = attachment.width,
              let height = attachment.height,
              width > 0,
              height > 0
        else {
            return attachment.mimeType.hasPrefix("video/")
                ? CGSize(width: maxWidth, height: maxWidth)
                : CGSize(width: maxWidth, height: 180)
        }

        let sourceSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let scale = min(maxWidth / sourceSize.width, maxHeight / sourceSize.height)
        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }
}

private enum BubbleImagePipeline {
    static func downsampleImage(at url: URL, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return downsampleImage(from: source, to: pointSize, scale: scale)
    }

    static func downsampleImage(data: Data, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return downsampleImage(from: source, to: pointSize, scale: scale)
    }

    static func decodeBlurHash(_ blurHash: String, size: CGSize) -> UIImage? {
        let width = max(Int(size.width / 8), 24)
        let height = max(Int(size.height / 8), 24)
        return BlurHash.decode(blurHash, width: width, height: height)
    }

    private static func downsampleImage(
        from source: CGImageSource,
        to pointSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private struct SwipeToReplyWrapper<Content: View>: View {
    let message: Message
    let onReply: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    private let threshold: CGFloat = 60

    var body: some View {
        HStack(spacing: 0) {
            content
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onChanged { value in
                            // Only allow right swipe (positive X) for received, left for sent
                            let translation = value.translation.width
                            if message.isOutgoing {
                                offset = min(0, translation) * 0.5 // Left swipe, dampened
                            } else {
                                offset = max(0, translation) * 0.5 // Right swipe, dampened
                            }
                        }
                        .onEnded { value in
                            let swipeAmount = abs(value.translation.width)
                            if swipeAmount > threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onReply()
                            }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                offset = 0
                            }
                        }
                )

            Spacer(minLength: 0)
        }
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            if abs(offset) > 10 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
                    .opacity(min(1, abs(offset) / threshold))
                    .scaleEffect(min(1, abs(offset) / threshold))
            }
        }
    }
}

// MARK: - Reaction Picker

private struct ReactionPickerView: View {
    let onSelect: (String) -> Void
    private let quickReactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSelect(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 28))
                        .frame(width: 44, height: 44)
                        .background(SanchrExportColors.surface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(SanchrExportColors.background)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Reaction Pills

private struct ReactionPillsView: View {
    let reactions: [Message.MessageReaction]
    let isOutgoing: Bool
    let onTapReaction: (String) -> Void

    /// Group reactions by emoji with count
    private var grouped: [(emoji: String, count: Int, userIds: [String])] {
        var dict: [String: [String]] = [:]
        for r in reactions {
            dict[r.emoji, default: []].append(r.userId)
        }
        return dict.map { (emoji: $0.key, count: $0.value.count, userIds: $0.value) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped, id: \.emoji) { item in
                Button {
                    onTapReaction(item.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(item.emoji)
                            .font(.system(size: 14))
                        if item.count > 1 {
                            Text("\(item.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SanchrExportColors.surface)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(SanchrExportColors.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
