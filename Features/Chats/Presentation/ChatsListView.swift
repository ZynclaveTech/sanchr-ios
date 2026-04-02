import SwiftUI

/// Conversation list screen showing all active chats.
/// Matches Figma: chats-list-screen with search, E2EE banner, and FAB.
struct ChatsListView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ChatsListViewModel()
    @State private var searchText = ""
    @State private var showNewConversation = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            mainContent
            fabButton
        }
        .navigationTitle("Chats")
        .navigationDestination(for: Conversation.self) { conversation in
            ChatDetailView(conversation: conversation)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showNewConversation = true
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    Button {
                        // TODO: New group
                    } label: {
                        Label("New Group", systemImage: "person.3")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.sanchrPrimary)
                }
            }
        }
        .refreshable {
            await viewModel.refresh(messageRepository: container.messageRepository)
        }
        .task {
            await viewModel.loadConversations(messageRepository: container.messageRepository)
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        Group {
            if viewModel.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                conversationList
            }
        }
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        List {
            // E2EE Banner
            if viewModel.showEncryptionBanner {
                encryptionBanner
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(
                        top: SanchrSpacing.xs,
                        leading: SanchrSpacing.md,
                        bottom: SanchrSpacing.xs,
                        trailing: SanchrSpacing.md
                    ))
            }

            // Loading indicator at top
            if viewModel.isLoading && viewModel.conversations.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.sanchrPrimary)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            // Conversation rows
            ForEach(viewModel.filteredConversations(searchText: searchText)) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRow(conversation: conversation)
                }
                .listRowBackground(Color.sanchrBackground(colorScheme))
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await viewModel.deleteConversation(conversation) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        Task { await viewModel.togglePin(conversation) }
                    } label: {
                        Label(
                            conversation.isPinned ? "Unpin" : "Pin",
                            systemImage: conversation.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .tint(.sanchrPrimary)

                    Button {
                        Task { await viewModel.toggleMute(conversation) }
                    } label: {
                        Label(
                            conversation.isMuted ? "Unmute" : "Mute",
                            systemImage: conversation.isMuted ? "bell" : "bell.slash"
                        )
                    }
                    .tint(.sanchrWarning)
                }
            }

            // Error message
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.sanchrWarning)
                    Text(error)
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search conversations")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: SanchrSpacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(SanchrColors.primary.opacity(0.1))
                    .frame(width: 96, height: 96)

                Image(systemName: "message.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(SanchrGradients.primaryDark)
            }

            Text("No conversations yet")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            Text("Start a new conversation to begin\nmessaging securely.")
                .font(SanchrTypography.body)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                .multilineTextAlignment(.center)

            Button {
                showNewConversation = true
            } label: {
                Text("Start a Chat")
                    .font(SanchrTypography.button)
                    .foregroundColor(.white)
                    .padding(.horizontal, SanchrSpacing.xxl)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(SanchrGradients.primaryDark)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
            }
            .sanchrPrimaryGlow()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sanchrBackground(colorScheme))
    }

    // MARK: - E2EE Banner

    private var encryptionBanner: some View {
        HStack(spacing: SanchrSpacing.xs) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14))
                .foregroundColor(SanchrColors.encryptionBadgeText)

            Text("Messages are end-to-end encrypted")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrColors.encryptionBadgeText)

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.dismissEncryptionBanner()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                    .padding(SanchrSpacing.xxs)
            }
        }
        .padding(.horizontal, SanchrSpacing.sm)
        .padding(.vertical, SanchrSpacing.xs)
        .background(SanchrColors.encryptionBadge)
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))
    }

    // MARK: - FAB (Floating Action Button)

    private var fabButton: some View {
        Button {
            showNewConversation = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x6366F1), Color(hex: 0x4C1D95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .sanchrElevatedShadow()
                .sanchrPrimaryGlow()
        }
        .padding(.trailing, SanchrSpacing.lg)
        .padding(.bottom, SanchrSpacing.lg)
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SanchrSpacing.sm) {
            // Avatar (48pt circle)
            avatar

            // Content
            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                // Top row: name + timestamp
                HStack {
                    Text(conversation.displayName)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        .lineLimit(1)

                    Spacer()

                    if let lastMessage = conversation.lastMessage {
                        Text(lastMessage.timestamp.chatTimestamp)
                            .font(SanchrTypography.chatTimestamp)
                            .foregroundColor(
                                conversation.unreadCount > 0
                                    ? .sanchrPrimary
                                    : Color.sanchrTextTertiary(colorScheme)
                            )
                    }
                }

                // Bottom row: preview + unread badge
                HStack(spacing: SanchrSpacing.xxs) {
                    // Delivery status for outgoing messages
                    if let lastMessage = conversation.lastMessage, lastMessage.isOutgoing {
                        Image(systemName: deliveryStatusIcon(lastMessage.status))
                            .font(.system(size: 12))
                            .foregroundColor(
                                lastMessage.status == .read
                                    ? .sanchrPrimary
                                    : Color.sanchrTextTertiary(colorScheme)
                            )
                    }

                    Text(messagePreview)
                        .font(SanchrTypography.caption)
                        .foregroundColor(
                            conversation.unreadCount > 0
                                ? Color.sanchrTextPrimary(colorScheme)
                                : Color.sanchrTextSecondary(colorScheme)
                        )
                        .lineLimit(1)
                        .fontWeight(conversation.unreadCount > 0 ? .medium : .regular)

                    Spacer()

                    // Pin indicator
                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                            .rotationEffect(.degrees(45))
                    }

                    // Mute indicator
                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                    }

                    // Unread badge (indigo circle with count)
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(SanchrTypography.micro)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.sanchrPrimary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, SanchrSpacing.xxs)
    }

    // MARK: - Avatar

    private var avatar: some View {
        Group {
            if let avatarURL = conversation.avatarURL {
                AsyncImage(url: avatarURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(SanchrColors.primary.opacity(0.15))
            .overlay {
                Text(conversation.displayName.prefix(1).uppercased())
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.sanchrPrimary)
            }
    }

    // MARK: - Helpers

    private var messagePreview: String {
        guard let lastMessage = conversation.lastMessage else { return "No messages yet" }
        switch lastMessage.content {
        case .text(let text): return text
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Voice message"
        case .document: return "Document"
        case .location: return "Location"
        case .contact(let name, _): return "Contact: \(name)"
        case .system(let event): return systemEventText(event)
        }
    }

    private func deliveryStatusIcon(_ status: Message.DeliveryStatus) -> String {
        switch status {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark"
        case .read: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }

    private func systemEventText(_ event: Message.SystemEvent) -> String {
        switch event {
        case .identityKeyChanged: return "Security code changed"
        case .disappearingTimerChanged: return "Disappearing timer changed"
        case .groupCreated: return "Group created"
        case .memberAdded: return "Member added"
        case .memberRemoved: return "Member removed"
        case .screenshotDetected: return "Screenshot detected"
        }
    }
}
