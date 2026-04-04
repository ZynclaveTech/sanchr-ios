import SwiftUI

/// Chat conversation detail view with message list and input.
/// Matches Figma: chat-screen with navigation bar, E2EE banner,
/// date separators, message bubbles, and rich input bar.
struct ChatDetailView: View {
    let conversation: Conversation
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ChatDetailViewModel()
    @FocusState private var isInputFocused: Bool
    @State private var showAttachmentPicker = false

    /// The recipient user for 1:1 conversations.
    private var recipient: User? {
        conversation.participants.first(where: { !$0.isLocalUser })
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - E2EE Banner
            e2eeBanner

            // MARK: - Messages
            messagesScrollView

            // MARK: - Typing Indicator
            if viewModel.peerIsTyping {
                typingIndicator
            }

            Divider()
                .foregroundColor(Color.sanchrDivider(colorScheme))

            // MARK: - Input Bar
            messageInputBar

            // MARK: - Bottom Toolbar
            bottomToolbar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // Navigation bar: avatar, name, status
            ToolbarItem(placement: .principal) {
                chatNavTitle
            }

            // Call and menu buttons
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: SanchrSpacing.sm) {
                    if let recipient {
                        Button {
                            Task {
                                try? await container.startCallUseCase.execute(
                                    recipientId: recipient.id,
                                    recipientName: recipient.displayName,
                                    isVideo: true
                                )
                            }
                        } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 16))
                        }
                        Button {
                            Task {
                                try? await container.startCallUseCase.execute(
                                    recipientId: recipient.id,
                                    recipientName: recipient.displayName,
                                    isVideo: false
                                )
                            }
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 16))
                        }
                    }
                }
                .foregroundColor(.sanchrPrimary)
            }
        }
        .task {
            await viewModel.loadMessages(
                conversationId: conversation.id,
                messageRepository: container.messageRepository
            )
        }
        .onAppear {
            viewModel.onConversationAppear(
                conversationId: conversation.id,
                pushManager: container.pushManager
            )
        }
        .onDisappear {
            viewModel.onConversationDisappear(pushManager: container.pushManager)
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
    }

    // MARK: - Navigation Title (Avatar + Name + Status)

    private var chatNavTitle: some View {
        HStack(spacing: SanchrSpacing.xs) {
            // Small avatar
            Circle()
                .fill(SanchrColors.primary.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay {
                    Text(conversation.displayName.prefix(1).uppercased())
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.semibold)
                        .foregroundColor(.sanchrPrimary)
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.displayName)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    .lineLimit(1)

                if let phone = recipient?.phoneNumber, !phone.isEmpty {
                    Text(phone)
                        .font(SanchrTypography.micro)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                } else {
                    Text("Encrypted chat")
                        .font(SanchrTypography.micro)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }
            }
        }
    }

    // MARK: - E2EE Banner

    private var e2eeBanner: some View {
        HStack(spacing: SanchrSpacing.xxs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
            Text("Messages are end-to-end encrypted")
                .font(SanchrTypography.micro)
        }
        .foregroundColor(SanchrColors.encryptionBadgeText)
        .padding(.vertical, SanchrSpacing.xxs)
        .frame(maxWidth: .infinity)
        .background(SanchrColors.encryptionBadge)
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: SanchrSpacing.xxs) {
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

                    // Load more indicator
                    if viewModel.isLoadingMore {
                        ProgressView()
                            .tint(.sanchrPrimary)
                            .padding(.vertical, SanchrSpacing.sm)
                    }

                    // Grouped messages with date separators
                    ForEach(viewModel.messageSections) { section in
                        // Date separator
                        dateSeparator(section.title)

                        ForEach(section.messages) { message in
                            MessageBubble(message: message, colorScheme: colorScheme)
                                .id(message.id)
                                .contextMenu {
                                    messageContextMenu(message)
                                }
                        }
                    }
                }
                .padding(.horizontal, SanchrSpacing.md)
                .padding(.vertical, SanchrSpacing.xs)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastId = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Date Separator

    private func dateSeparator(_ label: String) -> some View {
        HStack {
            Spacer()
            Text(label)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                .padding(.horizontal, SanchrSpacing.sm)
                .padding(.vertical, SanchrSpacing.xxxs)
                .background(Color.sanchrSurface(colorScheme).opacity(0.8))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.vertical, SanchrSpacing.xs)
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: SanchrSpacing.xs) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.sanchrTextTertiary(colorScheme))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, SanchrSpacing.sm)
            .padding(.vertical, SanchrSpacing.xs)
            .background(colorScheme == .dark ? SanchrColors.bubbleReceived : Color(hex: 0xF3F4F6))
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.bubble))

            Spacer()
        }
        .padding(.horizontal, SanchrSpacing.md)
        .padding(.bottom, SanchrSpacing.xxs)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Message Context Menu

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
            // TODO: Reply to message
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }

        Button {
            // TODO: Forward message
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

    // MARK: - Input Bar

    private var messageInputBar: some View {
        HStack(alignment: .bottom, spacing: SanchrSpacing.xs) {
            // Attachment button
            Button {
                showAttachmentPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.sanchrPrimary)
                    .frame(width: 36, height: 36)
                    .background(SanchrColors.primary.opacity(0.1))
                    .clipShape(Circle())
            }

            // Text field with inline buttons
            HStack(spacing: SanchrSpacing.xxs) {
                TextField("Type a message...", text: $viewModel.inputText, axis: .vertical)
                    .font(SanchrTypography.chatMessage)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)

                // Emoji button
                Button {
                    // TODO: Emoji picker
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 18))
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }

                // Attachment clip button
                Button {
                    showAttachmentPicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }
            }
            .padding(.horizontal, SanchrSpacing.sm)
            .padding(.vertical, SanchrSpacing.xs)
            .background(Color.sanchrSurface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.bubble))

            // Send button (indigo circle with arrow)
            Button {
                Task {
                    await viewModel.sendMessage(
                        conversationId: conversation.id,
                        recipientId: recipient?.id ?? "",
                        messageRepository: container.messageRepository,
                        signalProtocol: container.signalProtocol,
                        chatDataSource: container.chatDataSource,
                        sessionService: container.sessionService
                    )
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        hasInput
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color(hex: 0x6366F1), Color(hex: 0x4C1D95)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.sanchrTextTertiary(colorScheme).opacity(0.3))
                    )
                    .clipShape(Circle())
            }
            .disabled(!hasInput)
        }
        .padding(.horizontal, SanchrSpacing.sm)
        .padding(.vertical, SanchrSpacing.xs)
        .background(Color.sanchrSurfaceElevated(colorScheme))
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: SanchrSpacing.xxxxl) {
            Button {
                // TODO: Voice message
            } label: {
                VStack(spacing: SanchrSpacing.xxxs) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                    Text("Voice")
                        .font(SanchrTypography.micro)
                }
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }

            Button {
                // TODO: Open vault
            } label: {
                VStack(spacing: SanchrSpacing.xxxs) {
                    Image(systemName: "lock.rectangle.stack.fill")
                        .font(.system(size: 18))
                    Text("Vault")
                        .font(SanchrTypography.micro)
                }
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }
        }
        .padding(.vertical, SanchrSpacing.xxs)
        .frame(maxWidth: .infinity)
        .background(Color.sanchrSurfaceElevated(colorScheme))
    }

    // MARK: - Helpers

    private var hasInput: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    let colorScheme: ColorScheme

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 60) }

            VStack(
                alignment: message.isOutgoing ? .trailing : .leading, spacing: SanchrSpacing.xxxs
            ) {
                // Content
                messageContent

                // Timestamp + Read Receipt
                timestampRow
            }
            .padding(.horizontal, SanchrSpacing.sm)
            .padding(.vertical, SanchrSpacing.xs)
            .background(bubbleBackground)
            .clipShape(bubbleShape)

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .text(let text):
            Text(text)
                .font(SanchrTypography.chatMessage)
                .foregroundColor(
                    message.isOutgoing
                        ? SanchrColors.bubbleSentText
                        : SanchrColors.bubbleReceivedText
                )

        case .image(let attachment):
            // Image message with rounded preview
            VStack(alignment: .leading, spacing: SanchrSpacing.xxs) {
                RoundedRectangle(cornerRadius: SanchrRadius.sm)
                    .fill(Color.sanchrSurface(colorScheme))
                    .frame(width: 200, height: 150)
                    .overlay {
                        if let thumbnailURL = attachment.thumbnailURL {
                            AsyncImage(url: thumbnailURL) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                        } else {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))

                if let caption = attachment.caption, !caption.isEmpty {
                    Text(caption)
                        .font(SanchrTypography.chatMessage)
                        .foregroundColor(
                            message.isOutgoing
                                ? SanchrColors.bubbleSentText
                                : SanchrColors.bubbleReceivedText
                        )
                }
            }

        default:
            Text("[Unsupported content]")
                .font(SanchrTypography.caption)
                .italic()
                .foregroundColor(
                    message.isOutgoing
                        ? SanchrColors.bubbleSentText.opacity(0.7)
                        : Color.sanchrTextTertiary(colorScheme)
                )
        }
    }

    // MARK: - Timestamp Row

    private var timestampRow: some View {
        HStack(spacing: SanchrSpacing.xxxs) {
            Text(message.timestamp.messageTime)
                .font(SanchrTypography.micro)

            if message.isOutgoing {
                // Read receipt icon (double checkmark for read)
                Image(systemName: statusIcon)
                    .font(.system(size: 10))
                    .foregroundColor(
                        message.status == .read
                            ? Color.white.opacity(0.9)
                            : Color.white.opacity(0.6)
                    )
            }
        }
        .foregroundColor(
            message.isOutgoing
                ? SanchrColors.bubbleSentText.opacity(0.7)
                : Color.sanchrTextTertiary(colorScheme)
        )
    }

    // MARK: - Bubble Styling

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.isOutgoing {
            LinearGradient(
                colors: [Color(hex: 0x6366F1), Color(hex: 0x4C1D95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(hex: colorScheme == .dark ? 0x1F1F2E : 0xF3F4F6)
        }
    }

    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: SanchrRadius.bubble)
    }

    private var statusIcon: String {
        switch message.status {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark"
        case .read: return "checkmark.message.fill"
        case .failed: return "exclamationmark.circle"
        }
    }
}
