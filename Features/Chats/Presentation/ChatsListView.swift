import SwiftUI

/// Conversation list screen showing all active chats.
/// Matches Figma: chats-settings-screen.
struct ChatsListView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ChatsListViewModel()
    @State private var searchText = ""

    var body: some View {
        List {
            // MARK: - Encryption Banner
            if viewModel.showEncryptionBanner {
                encryptionBanner
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            // MARK: - Conversations
            ForEach(viewModel.filteredConversations(searchText: searchText)) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRow(conversation: conversation)
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))
                .swipeActions(edge: .trailing) {
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
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search conversations")
        .navigationTitle("Chats")
        .navigationDestination(for: Conversation.self) { conversation in
            ChatDetailView(conversation: conversation)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // TODO: New conversation composer
                } label: {
                    Image(systemName: "square.and.pencil")
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

    // MARK: - Subviews

    private var encryptionBanner: some View {
        HStack(spacing: SanchrSpacing.xs) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(SanchrColors.encryptionBadgeText)
            Text("All messages are end-to-end encrypted")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrColors.encryptionBadgeText)
            Spacer()
            Button {
                viewModel.showEncryptionBanner = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
        }
        .padding(SanchrSpacing.sm)
        .background(SanchrColors.encryptionBadge)
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SanchrSpacing.sm) {
            // Avatar
            Circle()
                .fill(Color.sanchrPrimary.opacity(0.2))
                .frame(width: 52, height: 52)
                .overlay {
                    Text(conversation.displayName.prefix(1).uppercased())
                        .font(SanchrTypography.cardTitle)
                        .foregroundColor(.sanchrPrimary)
                }

            // Content
            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
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

                HStack {
                    // TODO: Show message preview based on content type
                    Text(messagePreview)
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        .lineLimit(1)

                    Spacer()

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(SanchrTypography.micro)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.sanchrPrimary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, SanchrSpacing.xxs)
    }

    private var messagePreview: String {
        guard let lastMessage = conversation.lastMessage else { return "No messages yet" }
        switch lastMessage.content {
        case .text(let text): return text
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Voice message"
        case .document: return "Document"
        case .location: return "Location"
        case .contact: return "Contact"
        case .system: return "System message"
        }
    }
}
