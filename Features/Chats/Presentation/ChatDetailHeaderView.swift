import Kingfisher
import SwiftUI
import SanchrShared

// MARK: - Chat Detail Header
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.
// Owns the top header bar (avatar, title, status, call/search/overflow buttons,
// end-to-end-encryption banner) plus the action methods invoked from the
// overflow menu (archive / hide / refresh). Root-owned state is injected via
// @Binding so the root view remains the source of truth for alerts, sheets,
// and navigation destinations.

@MainActor
struct ChatDetailHeaderView: View {
    let conversation: Conversation

    @Bindable var presence: ChatPresenceState
    @Bindable var search: ChatSearchState
    @Binding var isConversationArchived: Bool
    @Binding var conversationActionErrorMessage: String?
    @Binding var showConversationInfo: Bool
    @Binding var callErrorMessage: String?
    let onDismiss: () -> Void
    /// Narrow callback so the header can seed peer presence/typing config
    /// from settings without holding a reference to the full view model.
    var onConfigurePeer: (_ showsPresence: Bool, _ showsTypingIndicators: Bool) -> Void
    /// Narrow callback so the header's search toggle can clear the search
    /// results without reaching into the view model.
    var onClearSearch: () -> Void

    @Environment(DependencyContainer.self) private var container

    private var recipient: User? {
        conversation.participants.first(where: { !$0.isLocalUser })
    }

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SanchrIconButton(
                    systemName: "chevron.left",
                    foreground: .sanchrPrimary,
                    background: SanchrExportColors.surface,
                    size: 36
                ) {
                    onDismiss()
                }

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

                SanchrGlassCluster(spacing: 12) {
                    HStack(spacing: 6) {
                        if let recipient {
                            if AppConfiguration.current.isVideoCallEnabled {
                                headerActionButton(icon: "video.fill") {
                                    Task {
                                        do {
                                            try await container.startCallUseCase.execute(
                                                recipientId: recipient.id,
                                                recipientName: recipient.displayName,
                                                isVideo: true
                                            )
                                        } catch {
                                            callErrorMessage = UserFacingError.message(for: error)
                                        }
                                    }
                                }
                            }

                            headerActionButton(icon: "phone.fill") {
                                Task {
                                    do {
                                        try await container.startCallUseCase.execute(
                                            recipientId: recipient.id,
                                            recipientName: recipient.displayName,
                                            isVideo: false
                                        )
                                    } catch {
                                        callErrorMessage = UserFacingError.message(for: error)
                                    }
                                }
                            }
                        }

                        headerActionButton(icon: "magnifyingglass") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                search.isSearching.toggle()
                                if !search.isSearching {
                                    onClearSearch()
                                }
                            }
                        }

                        Menu {
                            Button {
                                showConversationInfo = true
                            } label: {
                                Label("Conversation Info", systemImage: "info.circle")
                            }

                            Button {
                                Task { await toggleArchivedState() }
                            } label: {
                                Label(
                                    isConversationArchived ? "Unarchive" : "Archive",
                                    systemImage: isConversationArchived ? "tray.and.arrow.up" : "archivebox"
                                )
                            }

                            Button(role: .destructive) {
                                Task { await hideConversationFromDevice() }
                            } label: {
                                Label("Hide from This Device", systemImage: "eye.slash")
                            }
                        } label: {
                            headerMenuButton(icon: "ellipsis")
                        }
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
        .task {
            // refreshConversationState was previously called from the root
            // view's main .task; loadHeaderPreferences from its
            // scheduleDeferredEntryTasksIfNeeded path. Both now run on this
            // subview's appearance — behavior-equivalent because both only
            // mutate state that the header owns (archived flag + the
            // viewModel's peer presence/typing configuration).
            await refreshConversationState()
            await loadHeaderPreferences()
        }
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
            .sanchrShadow(0.06, radius: 4, y: 1)

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

    private var headerStatusText: String {
        if presence.showsTypingIndicators, (presence.peerIsTyping || presence.peerPresenceStatus == .typing) {
            return "Typing..."
        }

        if presence.showsPresence, !presence.peerPresenceHidden, conversation.type == .oneToOne {
            if presence.peerPresenceStatus == .online {
                return "Online now"
            }

            if let lastSeen = presence.peerLastSeen {
                return "Last seen \(lastSeen.relativePresenceDescription)"
            }
        }

        if let phone = recipient?.phoneNumber, !phone.isEmpty {
            return phone
        }

        return "Encrypted conversation"
    }

    private func headerActionButton(icon: String, action: @escaping () -> Void) -> some View {
        SanchrIconButton(
            systemName: icon,
            foreground: SanchrExportColors.textSecondary,
            background: SanchrExportColors.surface,
            size: SanchrSpacing.chatHeaderActionSize
        ) {
            action()
        }
    }

    private func headerMenuButton(icon: String) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .frame(width: SanchrSpacing.chatHeaderActionSize, height: SanchrSpacing.chatHeaderActionSize)
                    .sanchrGlass(role: .toolbarButton, interactive: true)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .frame(width: SanchrSpacing.chatHeaderActionSize, height: SanchrSpacing.chatHeaderActionSize)
                    .background(SanchrExportColors.surface)
                    .clipShape(Circle())
            }
        }
    }

    @MainActor
    private func toggleArchivedState() async {
        do {
            let nextValue = !isConversationArchived
            try await container.messageRepository.setConversationArchived(
                conversationId: conversation.id,
                isArchived: nextValue
            )
            isConversationArchived = nextValue
            if nextValue {
                onDismiss()
            }
        } catch {
            conversationActionErrorMessage = UserFacingError.message(for: error)
        }
    }

    @MainActor
    private func hideConversationFromDevice() async {
        do {
            try await container.messageRepository.hideConversationLocally(conversationId: conversation.id)
            onDismiss()
        } catch {
            conversationActionErrorMessage = UserFacingError.message(for: error)
        }
    }

    @MainActor
    private func refreshConversationState() async {
        if let storedConversation = try? await container.localDatabase.fetchConversation(id: conversation.id) {
            isConversationArchived = storedConversation.isArchived
        } else {
            isConversationArchived = conversation.isArchived
        }
    }

    private func loadHeaderPreferences() async {
        do {
            let settings = try await settingsDataSource.getSettings()
            // NOTE: presence visibility is enforced server-side via the
            // PresenceStatus.hidden enum on the wire. Hiding *my* own
            // presence must not stop me from seeing other people's —
            // the peer's privacy is conveyed via peerPresenceHidden in
            // handlePresenceUpdate. Typing, on the other hand, is a
            // local-only courtesy: if I've disabled typing indicators
            // for myself, I also don't want to see the other side's.
            onConfigurePeer(true, settings.typingIndicator)
        } catch {
            SanchrLogger.chat.error("Failed to load chat header preferences: \(error.localizedDescription)")
            // Server default for typing_indicator is true. Rather than silently
            // suppressing typing indicators for the entire session on a transient
            // network error, apply the safe default so the UI stays functional.
            onConfigurePeer(true, true)
        }
    }
}
