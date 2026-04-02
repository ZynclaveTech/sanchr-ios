import SwiftUI

/// Chat conversation detail view with message list and input.
/// Matches Figma: chat-screen.
struct ChatDetailView: View {
    let conversation: Conversation
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ChatDetailViewModel()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: SanchrSpacing.xxs) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message, colorScheme: colorScheme)
                                .id(message.id)
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

            Divider()

            // MARK: - Input Bar
            messageInputBar
        }
        .navigationTitle(conversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: SanchrSpacing.md) {
                    Button {
                        // TODO: Voice call
                    } label: {
                        Image(systemName: "phone.fill")
                    }
                    Button {
                        // TODO: Video call
                    } label: {
                        Image(systemName: "video.fill")
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
    }

    // MARK: - Input Bar

    private var messageInputBar: some View {
        HStack(spacing: SanchrSpacing.xs) {
            Button {
                // TODO: Attachment picker
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(.sanchrPrimary)
            }

            TextField("Message", text: $viewModel.inputText, axis: .vertical)
                .font(SanchrTypography.chatMessage)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .padding(.horizontal, SanchrSpacing.sm)
                .padding(.vertical, SanchrSpacing.xs)
                .background(Color.sanchrSurface(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.bubble))

            Button {
                Task {
                    await viewModel.sendMessage(
                        conversationId: conversation.id,
                        recipientId: conversation.participants.first(where: { !$0.isLocalUser })?.id ?? "",
                        messageRepository: container.messageRepository,
                        signalProtocol: container.signalProtocol
                    )
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundColor(
                        viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.sanchrTextTertiary(colorScheme)
                            : .sanchrPrimary
                    )
            }
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, SanchrSpacing.sm)
        .padding(.vertical, SanchrSpacing.xs)
        .background(Color.sanchrSurfaceElevated(colorScheme))
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    let colorScheme: ColorScheme

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: SanchrSpacing.xxxs) {
                // Content
                Group {
                    switch message.content {
                    case .text(let text):
                        Text(text)
                            .font(SanchrTypography.chatMessage)
                    default:
                        // TODO: Render media, location, contact, etc.
                        Text("[Unsupported content]")
                            .font(SanchrTypography.caption)
                            .italic()
                    }
                }
                .foregroundColor(message.isOutgoing ? SanchrColors.bubbleSentText : SanchrColors.bubbleReceivedText)

                // Timestamp + Status
                HStack(spacing: SanchrSpacing.xxxs) {
                    Text(message.timestamp.messageTime)
                        .font(SanchrTypography.micro)

                    if message.isOutgoing {
                        Image(systemName: statusIcon)
                            .font(.system(size: 10))
                    }
                }
                .foregroundColor(
                    message.isOutgoing
                        ? SanchrColors.bubbleSentText.opacity(0.7)
                        : Color.sanchrTextTertiary(colorScheme)
                )
            }
            .padding(.horizontal, SanchrSpacing.sm)
            .padding(.vertical, SanchrSpacing.xs)
            .background(message.isOutgoing ? SanchrColors.bubbleSent : SanchrColors.bubbleReceived)
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.bubble))

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }

    private var statusIcon: String {
        switch message.status {
        case .sending: "clock"
        case .sent: "checkmark"
        case .delivered: "checkmark.circle"
        case .read: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        }
    }
}
