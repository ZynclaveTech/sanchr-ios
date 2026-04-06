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
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showConversationInfo = false
    @State private var isScrolledToBottom = true
    @State private var newMessageCountWhileScrolled = 0
    @State private var scrollToBottomAction: (() -> Void)?

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

            composer
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showConversationInfo) {
            ConversationInfoView(conversation: conversation, recipient: recipient)
        }
        .photosPicker(isPresented: $showAttachmentPicker, selection: $selectedPhotoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                await handleSelectedPhoto(item)
            }
            selectedPhotoItem = nil
        }
        .task {
            viewModel.configurePeer(recipient)
            await viewModel.loadMessages(
                conversationId: conversation.id,
                messageRepository: container.messageRepository
            )
            await loadHeaderPreferences()
            if let recipient {
                container.realtimeService.trackPresencePeer(recipient.id)
            }

            // Mark conversation as read — gate receipt sending on privacy setting
            if let lastMessageId = viewModel.messages.last?.id {
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
                // Notify chat list to refresh unread counts
                NotificationCenter.default.post(name: .sanchrConversationStateDidChange, object: nil)
            }
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
                await viewModel.sendTypingIndicator(
                    conversationId: conversation.id,
                    isTyping: false,
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
                NotificationCenter.default.post(name: .sanchrConversationStateDidChange, object: nil)
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
            let isTyping = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Task {
                await viewModel.sendTypingIndicator(
                    conversationId: conversation.id,
                    isTyping: isTyping,
                    messageRepository: container.messageRepository,
                    canSend: container.privacySettings.canSendTypingIndicators
                )
            }
        }
        .onChange(of: isInputFocused) { _, focused in
            if !focused {
                // Keyboard dismissed — stop typing indicator
                Task {
                    await viewModel.sendTypingIndicator(
                        conversationId: conversation.id,
                        isTyping: false,
                        messageRepository: container.messageRepository,
                        canSend: container.privacySettings.canSendTypingIndicators
                    )
                }
            }
        }
        .onChange(of: viewModel.searchQuery) { _, query in
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
                guard viewModel.searchQuery == query else { return } // Cancelled by newer input
                await viewModel.searchMessages(
                    conversationId: conversation.id,
                    query: query,
                    localDatabase: container.localDatabase
                )
            }
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
                                viewModel.searchQuery = ""
                                viewModel.searchResults = []
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
                        Task {
                            await viewModel.searchMessages(
                                conversationId: conversation.id,
                                query: viewModel.searchQuery,
                                localDatabase: container.localDatabase
                            )
                        }
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
                    viewModel.searchQuery = ""
                    viewModel.searchResults = []
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: SanchrSpacing.messageGap) {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task {
                                await viewModel.loadMore(
                                    conversationId: conversation.id,
                                    messageRepository: container.messageRepository
                                )
                            }
                        }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .tint(.sanchrPrimary)
                            .padding(.vertical, 12)
                    }

                    ForEach(viewModel.messageSections) { section in
                        dateSeparator(section.title)

                        ForEach(section.messages) { message in
                            SwipeToReplyWrapper(message: message) {
                                viewModel.setReply(to: message)
                            } content: {
                                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                                    MessageBubble(message: message)

                                    if !message.reactions.isEmpty {
                                        ReactionPillsView(
                                            reactions: message.reactions,
                                            isOutgoing: message.isOutgoing,
                                            onTapReaction: { emoji in
                                                let userId = container.signalProtocol.localUserId
                                                viewModel.toggleReaction(
                                                    emoji: emoji,
                                                    messageId: message.id,
                                                    conversationId: conversation.id,
                                                    userId: userId
                                                )
                                                // TODO: Send via gRPC
                                            }
                                        )
                                    }
                                }
                            }
                            .id(message.id)
                            .contextMenu {
                                messageContextMenu(message)
                            } preview: {
                                // Horizontal reaction bar as context menu preview
                                VStack(spacing: 12) {
                                    HStack(spacing: 8) {
                                        let quickEmojis = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
                                        ForEach(quickEmojis, id: \.self) { emoji in
                                            Button {
                                                let userId = container.signalProtocol.localUserId
                                                viewModel.toggleReaction(
                                                    emoji: emoji,
                                                    messageId: message.id,
                                                    conversationId: conversation.id,
                                                    userId: userId
                                                )
                                            } label: {
                                                Text(emoji)
                                                    .font(.system(size: 30))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)

                                    // Message preview
                                    MessageBubble(message: message)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 8)
                                }
                                .frame(width: 320)
                            }
                        }
                    }

                    if viewModel.showsTypingIndicators && (viewModel.peerIsTyping || viewModel.peerPresenceStatus == .typing) {
                        typingPill
                    }

                    // Bottom anchor for scroll position detection
                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                        .onAppear { isScrolledToBottom = true; newMessageCountWhileScrolled = 0 }
                        .onDisappear { isScrolledToBottom = false }
                }
                .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .defaultScrollAnchor(.bottom)
            .background(SanchrExportColors.surfaceSoft)
            .onChange(of: viewModel.messages.count) { oldCount, newCount in
                guard oldCount > 0, newCount > oldCount else { return }
                let added = newCount - oldCount
                if isScrolledToBottom {
                    // At bottom — auto-scroll to new messages
                    if let lastID = viewModel.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                } else {
                    // Scrolled up — accumulate unread count, don't auto-scroll
                    newMessageCountWhileScrolled += added
                }
            }
            .onChange(of: isScrolledToBottom) { _, atBottom in
                if atBottom { newMessageCountWhileScrolled = 0 }
            }
            .onChange(of: viewModel.currentSearchIndex) { _, _ in
                if let resultId = viewModel.currentSearchResultId {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(resultId, anchor: .center)
                    }
                }
            }
            .onAppear {
                scrollToBottomAction = {
                    if let lastID = viewModel.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var scrollToBottomFAB: some View {
        Button {
            scrollToBottomAction?()
            newMessageCountWhileScrolled = 0
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
                    showAttachmentPicker = true
                } label: {
                    Image(systemName: "plus")
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
                        Button {} label: {
                            Image(systemName: "face.smiling")
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
                    // Mic button (placeholder for voice messages)
                    Button {} label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
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

    private func handleSelectedPhoto(_ item: PhotosPickerItem) async {
        let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })

        if isVideo {
            guard let videoData = try? await item.loadTransferable(type: Data.self) else { return }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            try? videoData.write(to: tempURL)

            let attachment = Message.MediaAttachment(
                url: tempURL, encryptionKey: Data(), encryptionIV: Data(),
                mimeType: "video/mp4", sizeBytes: Int64(videoData.count), thumbnailURL: nil
            )

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

            let attachment = Message.MediaAttachment(
                url: tempURL, encryptionKey: Data(), encryptionIV: Data(),
                mimeType: "image/jpeg", sizeBytes: Int64(imageData.count), thumbnailURL: nil
            )

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

private extension Date {
    var relativePresenceDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

struct MessageBubble: View {
    let message: Message

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

                    timestampRow
                        .padding(.top, 4)
                        .padding(.horizontal, 4)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(messageTextColor)
                    .multilineTextAlignment(.leading)

                if let url = LinkPreviewService.firstURL(in: text) {
                    LinkPreviewCard(url: url, isOutgoing: message.isOutgoing)
                }
            }

        case .image(let attachment):
            MediaBubbleImage(attachment: attachment, messageId: message.id, isOutgoing: message.isOutgoing)

        case .video(let attachment):
            MediaBubbleImage(attachment: attachment, messageId: message.id, isOutgoing: message.isOutgoing)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 4)
                }

        case .audio(let attachment):
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 20))
                    .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
                Text(formatDuration(attachment.durationSeconds ?? 0))
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(messageTextColor)
            }

        case .document(let attachment):
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.url.lastPathComponent)
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
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
        if message.isOutgoing {
            return UnevenRoundedRectangle(
                topLeadingRadius: main,
                bottomLeadingRadius: main,
                bottomTrailingRadius: tail,
                topTrailingRadius: main
            )
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: main,
            bottomLeadingRadius: tail,
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
    @Environment(DependencyContainer.self) private var container
    @State private var localImageURL: URL?
    @State private var isDownloading = false

    var body: some View {
        Group {
            if attachment.url.isFileURL {
                // Local file (sending/optimistic)
                if let uiImage = UIImage(contentsOfFile: attachment.url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: 220, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            } else if let localURL = localImageURL,
                      let uiImage = UIImage(contentsOfFile: localURL.path) {
                // Downloaded + decrypted
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                // Placeholder while downloading
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOutgoing ? Color.white.opacity(0.15) : SanchrExportColors.surfaceSoft)
                    .frame(width: 200, height: 150)
                    .overlay {
                        if isDownloading {
                            ProgressView()
                                .tint(isOutgoing ? .white : .sanchrPrimary)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundColor(isOutgoing ? .white.opacity(0.5) : SanchrExportColors.textTertiary)
                        }
                    }
            }
        }
        .task {
            guard !attachment.url.isFileURL, localImageURL == nil else { return }
            isDownloading = true
            let ext = attachment.mimeType.contains("png") ? "png" : "jpg"
            // Check cache first
            if let cached = await container.mediaDownloadManager.cachedURL(for: messageId, ext: ext) {
                localImageURL = cached
                isDownloading = false
                return
            }
            // Download + decrypt
            do {
                let url = try await container.mediaDownloadManager.download(
                    messageId: messageId,
                    attachment: attachment
                )
                localImageURL = url
            } catch {
                SanchrLogger.media.error("Media download failed: \(error.localizedDescription)")
            }
            isDownloading = false
        }
    }
}

private struct LinkPreviewCard: View {
    let url: URL
    let isOutgoing: Bool
    @State private var preview: LinkPreviewData?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let preview {
                VStack(alignment: .leading, spacing: 0) {
                    if let imageData = preview.imageData, let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxHeight: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .onTapGesture {
                    UIApplication.shared.open(url)
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(isOutgoing ? .white : Color.sanchrPrimary)
                    Text(url.host ?? "Loading...")
                        .font(SanchrTypography.micro)
                        .foregroundColor(isOutgoing ? Color.white.opacity(0.6) : SanchrExportColors.textTertiary)
                }
                .padding(8)
            }
        }
        .task {
            preview = await LinkPreviewService.shared.preview(for: url)
            isLoading = false
        }
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
