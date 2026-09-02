import Kingfisher
import SwiftUI
import SanchrShared

// MARK: - Conversation Row
// Extracted from ChatsListView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct ConversationRow: View {
    let conversation: Conversation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            avatarWithStatus

            VStack(alignment: .leading, spacing: SanchrSpacing.namePreviewGap) {
                HStack(alignment: .center, spacing: 10) {
                    Text(conversation.displayName)
                        .font(SanchrTypography.conversationName)
                        .tracking(SanchrTypography.conversationNameTracking)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let lastMessage = conversation.lastMessage {
                        Text(lastMessage.timestamp.chatTimestamp)
                            .font(SanchrTypography.chatTimestamp)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                }

                HStack(spacing: 6) {
                    if let lastMessage = conversation.lastMessage, lastMessage.isOutgoing {
                        deliveryStatusView(lastMessage.status)
                    }

                    Group {
                        // A draft outranks the last message: it is the thing
                        // the user left unfinished, and it is why they are
                        // looking at this row. It does not outrank "typing…",
                        // which is about the other person and is live.
                        if let draft = draftPreview {
                            (Text("Draft: ")
                                .font(SanchrTypography.conversationPreviewBold)
                                .foregroundColor(SanchrColors.error)
                            + Text(draft)
                                .font(SanchrTypography.conversationPreview)
                                .foregroundColor(SanchrExportColors.textSecondary))
                            .lineLimit(1)
                        } else if conversation.type == .group,
                           let lastMessage = conversation.lastMessage,
                           !lastMessage.isOutgoing,
                           let sender = conversation.participants.first(where: { $0.id == lastMessage.senderId }) {
                            (Text((sender.displayName.components(separatedBy: " ").first ?? sender.displayName) + ": ")
                                .font(SanchrTypography.conversationPreviewBold)
                                .foregroundColor(Color.sanchrGroupSender(colorScheme))
                            + Text(messagePreviewText)
                                .font(
                                    conversation.unreadCount > 0
                                        ? SanchrTypography.conversationPreviewBold
                                        : SanchrTypography.conversationPreview
                                )
                                .foregroundColor(
                                    conversation.unreadCount > 0
                                        ? SanchrExportColors.textPrimary
                                        : SanchrExportColors.textSecondary
                                ))
                            .lineLimit(1)
                        } else {
                            Text(messagePreview)
                                .font(
                                    conversation.unreadCount > 0
                                        ? SanchrTypography.conversationPreviewBold
                                        : SanchrTypography.conversationPreview
                                )
                                .foregroundColor(
                                    conversation.unreadCount > 0
                                        ? SanchrExportColors.textPrimary
                                        : SanchrExportColors.textSecondary
                                )
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(SanchrTypography.unreadBadge)
                            .foregroundColor(.white)
                            .frame(minWidth: SanchrSpacing.unreadBadgeSize)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(SanchrColors.primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, SanchrSpacing.chatRowHPadding)
        .padding(.vertical, SanchrSpacing.chatRowVPadding)
        .contentShape(Rectangle())
    }

    private var avatarWithStatus: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarImage
                .overlay {
                    Circle()
                        .stroke(Color.sanchrAvatarBorder(colorScheme), lineWidth: 2)
                }
                .sanchrShadow(0.06, radius: 4, y: 1)
            statusDot
        }
        .frame(width: SanchrSpacing.chatAvatarSize, height: SanchrSpacing.chatAvatarSize)
    }

    private var avatarImage: some View {
        Group {
            if conversation.type == .group {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xEC4899), Color(hex: 0x8B5CF6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 16, height: 16)
                            .overlay {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(Color(hex: 0x9CA3AF))
                            }
                            .offset(x: 1, y: 1)
                    }
            } else if let avatarURL = conversation.avatarURL {
                KFImage(avatarURL)
                    .resizable()
                    .placeholder { avatarPlaceholder }
                    .fade(duration: 0.2)
                    .scaledToFill()
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: SanchrSpacing.chatAvatarSize, height: SanchrSpacing.chatAvatarSize)
        .clipShape(Circle())
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(SanchrColors.primary.opacity(0.14))
            .overlay {
                Text(conversation.displayName.prefix(1).uppercased())
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.sanchrPrimary)
            }
    }

    @ViewBuilder
    private var statusDot: some View {
        let otherUser = conversation.participants.first(where: { !$0.isLocalUser })
        if let user = otherUser, conversation.type == .oneToOne {
            Circle()
                .fill(statusColor(for: user.status))
                .frame(width: SanchrSpacing.statusIndicatorSize, height: SanchrSpacing.statusIndicatorSize)
                .overlay {
                    Circle()
                        .stroke(Color.sanchrAvatarBorder(colorScheme), lineWidth: SanchrSpacing.statusIndicatorBorder)
                }
                .offset(x: 1, y: 1)
                .modifier(PulseModifier(isActive: user.status == .online))
        }
    }

    @ViewBuilder
    private func deliveryStatusView(_ status: Message.DeliveryStatus) -> some View {
        switch status {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundColor(SanchrExportColors.textTertiary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(SanchrExportColors.textTertiary)
        case .delivered, .read:
            ZStack(alignment: .leading) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .offset(x: 5)
            }
            .foregroundColor(status == .read ? SanchrColors.accent : SanchrExportColors.textTertiary)
            .frame(width: 18)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.sanchrError)
        }
    }

    private func statusColor(for status: User.Status) -> Color {
        switch status {
        case .online, .typing:
            return SanchrColors.statusOnline
        case .away:
            return SanchrColors.statusAway
        case .offline:
            return SanchrColors.statusOffline
        }
    }

    /// Unsent text for this chat, when there is any and the peer is not
    /// actively typing.
    private var draftPreview: String? {
        let isPeerTyping = conversation.participants
            .first(where: { !$0.isLocalUser })?.status == .typing
        guard !isPeerTyping else { return nil }
        guard let draft = conversation.draftText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !draft.isEmpty
        else {
            return nil
        }
        return draft
    }

    private var messagePreview: String {
        if let otherUser = conversation.participants.first(where: { !$0.isLocalUser }),
           otherUser.status == .typing
        {
            return "typing..."
        }

        guard let lastMessage = conversation.lastMessage else { return "No messages yet" }
        switch lastMessage.content {
        case .text(let text):
            return text
        case .image:
            return "Photo"
        case .video:
            return "Video"
        case .audio:
            return "Voice message"
        case .document:
            return "Document"
        case .location:
            return "Location"
        case .contact(let name, _):
            return "Contact: \(name)"
        case .system(let event):
            return systemEventText(event)
        }
    }

    private var messagePreviewText: String {
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

    private func systemEventText(_ event: Message.SystemEvent) -> String {
        event.displayLabel
    }
}

// Visibility promoted from private to module-internal for cross-file access.
struct ChatRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .background(
                configuration.isPressed
                    ? SanchrColors.primary.opacity(0.05)
                    : Color.clear
            )
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// Visibility promoted from private to module-internal for cross-file access.
struct PulseModifier: ViewModifier {
    let isActive: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive && isPulsing ? 0.5 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if isActive { isPulsing = true }
            }
            .onChange(of: isActive) { _, newValue in
                isPulsing = newValue
            }
    }
}
