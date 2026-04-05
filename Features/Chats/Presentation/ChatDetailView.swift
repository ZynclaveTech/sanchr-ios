import Kingfisher
import SwiftUI

struct ChatDetailView: View {
    let conversation: Conversation

    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ChatDetailViewModel()
    @FocusState private var isInputFocused: Bool
    @State private var showAttachmentPicker = false
    @State private var showConversationInfo = false

    private var recipient: User? {
        conversation.participants.first(where: { !$0.isLocalUser })
    }

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if viewModel.showsTypingIndicators && (viewModel.peerIsTyping || viewModel.peerPresenceStatus == .typing) {
                typingPill
                    .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                    .padding(.top, 8)
            }

            messagesScrollView

            composer
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showConversationInfo) {
            ConversationInfoView(conversation: conversation, recipient: recipient)
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
        .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimePresenceUpdated)) { note in
            guard
                let userInfo = note.userInfo,
                let presence = userInfo[RealtimeNotificationKey.presence] as? Vync_Messaging_PresenceUpdate
            else {
                return
            }

            viewModel.handlePresenceUpdate(presence, participantId: recipient?.id)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .frame(width: SanchrSpacing.chatHeaderActionSize, height: SanchrSpacing.chatHeaderActionSize)
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

                    Menu {
                        Button {
                            showConversationInfo = true
                        } label: {
                            Label("Chat Settings", systemImage: "person.crop.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .frame(width: SanchrSpacing.chatHeaderActionSize, height: SanchrSpacing.chatHeaderActionSize)
                    }
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

    private var typingPill: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(SanchrExportColors.textTertiary)
                        .frame(width: 6, height: 6)
                }
            }
            Text("Typing...")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
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
                            MessageBubble(message: message)
                                .id(message.id)
                                .contextMenu {
                                    messageContextMenu(message)
                                }
                        }
                    }
                }
                .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .background(SanchrExportColors.surfaceSoft)
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func dateSeparator(_ label: String) -> some View {
        Text(label)
            .font(SanchrTypography.captionSmall)
            .foregroundColor(SanchrExportColors.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(SanchrExportColors.surface)
            .clipShape(Capsule())
            .padding(.vertical, 6)
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
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                showAttachmentPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SanchrColors.primary)
                    .frame(width: 40, height: 40)
                    .background(SanchrExportColors.surfaceMuted)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                TextField("Type a message...", text: $viewModel.inputText, axis: .vertical)
                    .font(SanchrTypography.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isInputFocused)

                Button {} label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
                .buttonStyle(.plain)

                Button {
                    showAttachmentPicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

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
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(hasInput ? SanchrColors.primary : SanchrExportColors.textTertiary.opacity(0.3))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasInput)
        }
        .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            SanchrExportColors.surface
                .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: -6)
        )
    }

    private var hasInput: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 54) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
                messageContent
                timestampRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .clipShape(bubbleShape)

            if !message.isOutgoing { Spacer(minLength: 54) }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .text(let text):
            Text(text)
                .font(SanchrTypography.body)
                .foregroundColor(messageTextColor)
                .multilineTextAlignment(.leading)

        case .image(let attachment):
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: 0xE5E7EB))
                    .frame(width: 210, height: 156)
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
                                .font(.system(size: 34))
                                .foregroundColor(SanchrExportColors.textTertiary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let caption = attachment.caption, !caption.isEmpty {
                    Text(caption)
                        .font(SanchrTypography.body)
                        .foregroundColor(messageTextColor)
                }
            }

        default:
            Text("[Unsupported content]")
                .font(SanchrTypography.caption)
                .foregroundColor(messageTextColor.opacity(0.72))
        }
    }

    private var timestampRow: some View {
        HStack(spacing: 4) {
            Text(message.timestamp.messageTime)
                .font(SanchrTypography.micro)

            if message.isOutgoing {
                Image(systemName: statusIcon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(message.status == .read ? Color.white.opacity(0.95) : Color.white.opacity(0.72))
            }
        }
        .foregroundColor(message.isOutgoing ? Color.white.opacity(0.75) : SanchrExportColors.textSecondary)
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
        if message.isOutgoing {
            return UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: 20,
                bottomTrailingRadius: 6,
                topTrailingRadius: 20
            )
        }

        return UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: 6,
            bottomTrailingRadius: 20,
            topTrailingRadius: 20
        )
    }

    private var messageTextColor: Color {
        message.isOutgoing ? .white : SanchrExportColors.textPrimary
    }

    private var statusIcon: String {
        switch message.status {
        case .sending:
            return "clock"
        case .sent:
            return "checkmark"
        case .delivered, .read:
            return "checkmark.double"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }
}
