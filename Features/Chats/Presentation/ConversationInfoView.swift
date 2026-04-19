@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import CryptoKit
import Kingfisher
import SanchrShared
import SwiftUI

struct ConversationInfoView: View {
    let conversation: Conversation
    let recipient: User?

    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var refreshedRecipient: User?
    @State private var notificationsMuted = false
    @State private var mediaVisibility = true
    @State private var sanchrModeEnabled = false
    @State private var isConversationArchived: Bool
    @State private var showDisappearingMessages = false
    @State private var showVaultMedia = false
    @State private var showWallpaper = false
    @State private var recentMedia: [Message] = []
    @State private var totalMediaCount: Int = 0
    @State private var allChatMedia: [Message] = []
    @State private var galleryPresentation: ConversationInfoGalleryPresentation?
    @State private var showSharedContent = false
    @State private var showSearchConversation = false
    @State private var showExportChat = false
    @State private var showClearChat = false
    @State private var showBlockContact = false
    @State private var showReportContact = false
    @State private var conversationActionErrorMessage: String?

    init(conversation: Conversation, recipient: User?) {
        self.conversation = conversation
        self.recipient = recipient
        _notificationsMuted = State(initialValue: conversation.isMuted)
        _mediaVisibility = State(
            initialValue: ChatMediaVisibilityStore.isVisibleInGallery(conversationId: conversation.id)
        )
        _isConversationArchived = State(initialValue: conversation.isArchived)
    }

    /// Use refreshed data if available, fall back to initial snapshot
    private var activeRecipient: User? {
        refreshedRecipient ?? recipient
    }

    private var recipientHasPhone: Bool {
        if let phone = activeRecipient?.phoneNumber, !phone.isEmpty { return true }
        return false
    }

    private var recipientPhoneDisplay: String {
        if let phone = activeRecipient?.phoneNumber, !phone.isEmpty {
            return phone
        }
        return "Encrypted conversation"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                profileSection
                mediaSection
                securitySection
                chatPreferencesSection
                sanchrModeSection
                disappearingMessagesSection
                chatActionsSection
                dangerZoneSection
                Color.clear.frame(height: 32)
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Chat Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sanchrInteractivePopEnabled()
        .task {
            // Fetch fresh contacts from server to get phone numbers
            guard let recipientId = recipient?.id else { return }
            do {
                let contacts = try await container.contactRepository.fetchContacts()
                if let fresh = contacts.first(where: { $0.id == recipientId }) {
                    refreshedRecipient = fresh
                }
            } catch {
                SanchrLogger.chat.warning(
                    "Chat Settings: failed to refresh contacts: \(error.localizedDescription)")
            }
        }
        .task {
            await loadConversationPreferences()
        }
        .navigationDestination(isPresented: $showWallpaper) {
            WallpaperThemeView(conversationId: conversation.id)
        }
        .navigationDestination(isPresented: $showSharedContent) {
            SharedContentView(conversation: conversation)
        }
        .fullScreenCover(item: $galleryPresentation) { presentation in
            // Reuse the bubble-viewers MediaGalleryView. Map message
            // entries into the gallery's GalleryItem type.
            let galleryItems = presentation.items.compactMap { msg -> GalleryItem? in
                switch msg.content {
                case .image: return GalleryItem(id: msg.id, kind: .image, message: msg)
                case .video: return GalleryItem(id: msg.id, kind: .video, message: msg)
                default: return nil
                }
            }
            MediaGalleryView(
                presentation: MediaGalleryCoordinator.GalleryPresentation(
                    items: galleryItems,
                    initialIndex: presentation.initialIndex
                ),
                resolver: container.chatMediaResolver,
                onDismiss: { galleryPresentation = nil }
            )
        }
        .task {
            await loadRecentMediaIfNeeded()
        }
        .navigationDestination(isPresented: $showDisappearingMessages) {
            DisappearingMessagesView(conversationId: conversation.id)
        }
        .navigationDestination(isPresented: $showVaultMedia) {
            VaultMediaView(conversationId: conversation.id)
        }
        .confirmationDialog("Export Chat", isPresented: $showExportChat) {
            Button("Export with Media") {}
            Button("Export without Media") {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how to export this conversation")
        }
        .alert("Clear Chat", isPresented: $showClearChat) {
            Button("Clear All Messages", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will permanently delete all messages in this conversation. This action cannot be undone."
            )
        }
        .alert("Block Contact", isPresented: $showBlockContact) {
            Button("Block", role: .destructive) {
                Task {
                    guard let userId = recipient?.id else { return }
                    let dataSource = ContactDataSource(
                        grpcClient: container.grpcClient,
                        localDatabase: container.localDatabase
                    )
                    do {
                        try await dataSource.blockContact(userId: userId)
                        SanchrLogger.sync.info("Blocked contact \(userId.prefix(8))… from ConversationInfo")
                        dismiss()
                    } catch {
                        SanchrLogger.sync.error("Failed to block contact \(userId.prefix(8))…: \(error)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Blocked contacts cannot send you messages or call you. You can unblock them later from Settings."
            )
        }
        .alert("Report Contact", isPresented: $showReportContact) {
            Button("Report", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Report this contact for inappropriate behavior. We'll review your report and take appropriate action."
            )
        }
        .alert("Couldn't update conversation", isPresented: Binding(
            get: { conversationActionErrorMessage != nil },
            set: { if !$0 { conversationActionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversationActionErrorMessage ?? "")
        }
    }

    private var profileSection: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarURL = conversation.avatarURL {
                        KFImage(avatarURL)
                            .resizable()
                            .placeholder {
                                Circle()
                                    .fill(SanchrColors.primary.opacity(0.14))
                                    .overlay {
                                        Text(conversation.displayName.prefix(1).uppercased())
                                            .font(SanchrTypography.sectionHeader)
                                            .foregroundColor(.sanchrPrimary)
                                    }
                            }
                            .fade(duration: 0.2)
                            .scaledToFill()
                    } else {
                        Circle()
                            .fill(SanchrColors.primary.opacity(0.14))
                            .overlay {
                                Text(conversation.displayName.prefix(1).uppercased())
                                    .font(SanchrTypography.sectionHeader)
                                    .foregroundColor(.sanchrPrimary)
                            }
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(Color.white, lineWidth: 2)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text(recipientPhoneDisplay)
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(
                        recipientHasPhone
                            ? SanchrExportColors.textSecondary
                            : SanchrExportColors.textTertiary
                    )

                Text("End-to-End Encrypted")
                    .font(SanchrTypography.captionSmall)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrColors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SanchrColors.accent.opacity(0.1))
                    .clipShape(Capsule())
                    .padding(.top, 6)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary.opacity(0.05), SanchrColors.accent.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Section: Media & Links

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Media & Links")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Spacer()
                Button {
                    showSharedContent = true
                } label: {
                    Text("View All")
                        .font(SanchrTypography.messageBubbleText)
                        .fontWeight(.medium)
                        .foregroundColor(SanchrColors.primary)
                }
                .buttonStyle(.plain)
            }

            if recentMedia.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                        .foregroundColor(SanchrExportColors.textTertiary)
                    Text("No media shared yet")
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(SanchrExportColors.textSecondary)
                    Text("Photos, videos, and files shared in this conversation will appear here")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(recentMedia, id: \.id) { message in
                        ConversationInfoMediaThumbnail(
                            message: message,
                            resolver: container.chatMediaResolver
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture {
                            galleryPresentation = ConversationInfoGalleryPresentation(
                                items: allChatMedia,
                                initialIndex: allChatMedia.firstIndex(where: { $0.id == message.id }) ?? 0
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    private func loadRecentMediaIfNeeded() async {
        guard recentMedia.isEmpty else { return }
        let messages = (try? await container.localDatabase.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 500
        )) ?? []
        let media = messages.filter { msg in
            switch msg.content {
            case .image, .video: return true
            default: return false
            }
        }
        let sorted = media.sorted { $0.timestamp < $1.timestamp }
        allChatMedia = sorted
        totalMediaCount = sorted.count
        recentMedia = Array(sorted.suffix(6).reversed())
    }

    // MARK: - Section: Security & Privacy

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Security & Privacy")
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.semibold)
                .foregroundColor(SanchrExportColors.textPrimary)
                .padding(.bottom, 16)

            NavigationLink {
                VerifySecurityCodeView(conversation: conversation)
            } label: {
                settingsRow(
                    icon: "lock.shield.fill",
                    iconBg: SanchrColors.primary.opacity(0.1),
                    iconColor: SanchrColors.primary,
                    title: "Encryption",
                    subtitle: "Verify security code and view keys"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Chat Preferences

    private var chatPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat Preferences")
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.semibold)
                .foregroundColor(SanchrExportColors.textPrimary)
                .padding(.bottom, 16)

            settingsToggleRow(
                icon: "bell.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Mute Conversation",
                subtitle: "Turn off notifications for this chat",
                isOn: notificationsMutedBinding
            )

            settingsToggleRow(
                icon: "photo.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Media Visibility",
                subtitle: "Allow media from this chat in Photos auto-save",
                isOn: mediaVisibilityBinding
            )

            Button {
                showWallpaper = true
            } label: {
                settingsRow(
                    icon: "paintpalette.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Wallpaper & Theme",
                    subtitle: "Customize chat appearance"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Sanchr Mode

    private var sanchrModeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SanchrColors.primaryDark, SanchrColors.primary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sanchr Mode")
                        .font(SanchrTypography.messageBubbleText)
                        .fontWeight(.bold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text("Enhanced privacy & incognito")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $sanchrModeEnabled)
                    .labelsHidden()
                    .tint(.sanchrPrimary)
            }
            .padding(.vertical, 12)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SanchrColors.primary)
                    .padding(.top, 1)
                Text(
                    "Sanchr Mode hides notification previews, detects screenshots after capture, and shields content during screen recording or mirroring."
                )
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
            }
            .padding(.top, 12)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [
                    SanchrColors.primaryDark.opacity(0.05), SanchrColors.primary.opacity(0.05),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Disappearing Messages

    private var disappearingMessagesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showDisappearingMessages = true
            } label: {
                settingsRow(
                    icon: "clock.arrow.circlepath",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Disappearing Messages",
                    subtitle: "Off"
                )
            }
            .buttonStyle(.plain)

            Button {
                showVaultMedia = true
            } label: {
                settingsRow(
                    icon: "lock.shield.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Vault Media",
                    subtitle: "Self-destructing photos & videos"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Chat Actions

    private var chatActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await toggleArchivedState() }
            } label: {
                settingsRow(
                    icon: isConversationArchived ? "tray.and.arrow.up.fill" : "archivebox.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: isConversationArchived ? "Unarchive Chat" : "Archive Chat",
                    subtitle: isConversationArchived
                        ? "Return this chat to your main list"
                        : "Move this chat out of your main list"
                )
            }
            .buttonStyle(.plain)

            Button {
                Task { await hideConversationFromDevice() }
            } label: {
                settingsRow(
                    icon: "eye.slash.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Hide from This Device",
                    subtitle: "Remove this chat from this device only"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Button {
                showExportChat = true
            } label: {
                settingsRow(
                    icon: "square.and.arrow.down.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Export Chat",
                    subtitle: "Save conversation backup"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Button {
                showClearChat = true
            } label: {
                settingsRow(
                    icon: "trash.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Clear Chat",
                    subtitle: "Delete all messages"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
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
                dismiss()
            }
        } catch {
            conversationActionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func hideConversationFromDevice() async {
        do {
            try await container.messageRepository.hideConversationLocally(conversationId: conversation.id)
            dismiss()
        } catch {
            conversationActionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadConversationPreferences() async {
        if let storedConversation = try? await container.localDatabase.fetchConversation(id: conversation.id) {
            notificationsMuted = storedConversation.isMuted
            isConversationArchived = storedConversation.isArchived
        } else {
            notificationsMuted = conversation.isMuted
            isConversationArchived = conversation.isArchived
        }
        mediaVisibility = ChatMediaVisibilityStore.isVisibleInGallery(conversationId: conversation.id)
    }

    private var notificationsMutedBinding: Binding<Bool> {
        Binding(
            get: { notificationsMuted },
            set: { newValue in
                let previousValue = notificationsMuted
                notificationsMuted = newValue
                Task { await updateNotificationMute(from: previousValue, to: newValue) }
            }
        )
    }

    private var mediaVisibilityBinding: Binding<Bool> {
        Binding(
            get: { mediaVisibility },
            set: { newValue in
                mediaVisibility = newValue
                ChatMediaVisibilityStore.setVisibleInGallery(
                    newValue,
                    conversationId: conversation.id
                )
            }
        )
    }

    @MainActor
    private func updateNotificationMute(from oldValue: Bool, to newValue: Bool) async {
        guard oldValue != newValue else { return }
        do {
            var request = Sanchr_Notifications_SetConversationNotificationPrefsRequest()
            request.conversationID = conversation.id
            request.muted = newValue
            _ = try await container.notificationServiceClient.setConversationNotificationPrefs(
                request
            )

            try await container.messageRepository.setConversationMuted(
                conversationId: conversation.id,
                isMuted: newValue
            )
        } catch {
            notificationsMuted = oldValue
            conversationActionErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Section: Danger Zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showBlockContact = true
            } label: {
                dangerRow(icon: "person.fill.xmark", title: "Block Contact")
            }
            .buttonStyle(.plain)

            Button {
                showReportContact = true
            } label: {
                dangerRow(icon: "flag.fill", title: "Report Contact")
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Reusable Helper Functions

    private func settingsRow(
        icon: String,
        iconBg: Color,
        iconColor: Color,
        title: String,
        subtitle: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(iconBg)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func settingsToggleRow(
        icon: String,
        iconBg: Color,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(iconBg)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
        .padding(.vertical, 12)
    }

    private func dangerRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: 0xFEF2F2))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sanchrError)
                }

            Text(title)
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.medium)
                .foregroundColor(.sanchrError)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SanchrColors.error.opacity(0.6))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Media Gradient Helper

    private func mediaGradient(for index: Int) -> LinearGradient {
        let gradients: [[Color]] = [
            [Color(hex: 0xE0E7FF), Color(hex: 0xC7D2FE)],
            [Color(hex: 0xFCE7F3), Color(hex: 0xFBCFE8)],
            [Color(hex: 0xCFFAFE), Color(hex: 0xA5F3FC)],
            [Color(hex: 0xF3E8FF), Color(hex: 0xE9D5FF)],
            [Color(hex: 0xDBEAFE), Color(hex: 0xBFDBFE)],
            [Color(hex: 0xFEF3C7), Color(hex: 0xFDE68A)],
        ]
        let pair = gradients[index % gradients.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - DisappearingMessagesView

private struct DisappearingMessagesView: View {
    let conversationId: String

    @State private var selectedDuration: Int = 0

    private let options: [(String, String, Int)] = [
        ("Off", "Messages won't be deleted", 0),
        ("5 minutes", "For sensitive conversations", 300),
        ("1 hour", "Short-lived messages", 3600),
        ("24 hours", "Daily cleanup", 86400),
        ("7 days", "Weekly cleanup", 604800),
        ("30 days", "Monthly cleanup", 2_592_000),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Info banner
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(SanchrColors.primary)
                        .padding(.top, 2)
                    Text(
                        "When enabled, new messages will disappear after the selected time. This applies to both sides of the conversation."
                    )
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrExportColors.textSecondary)
                }
                .padding(16)
                .background(SanchrColors.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                // Timer options
                ForEach(0..<options.count, id: \.self) { index in
                    let option = options[index]
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDuration = option.2
                        }
                        DisappearingTimerStore.setDuration(
                            conversationId: conversationId,
                            secs: Int64(option.2)
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(
                                    selectedDuration == option.2
                                        ? SanchrColors.primary.opacity(0.1)
                                        : SanchrExportColors.surfaceSoft
                                )
                                .frame(width: 40, height: 40)
                                .overlay {
                                    Image(systemName: option.2 == 0 ? "xmark" : "clock.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(
                                            selectedDuration == option.2
                                                ? SanchrColors.primary
                                                : SanchrExportColors.textSecondary)
                                }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.0)
                                    .font(SanchrTypography.messageBubbleText)
                                    .fontWeight(.medium)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                Text(option.1)
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                            }

                            Spacer()

                            if selectedDuration == option.2 {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(SanchrColors.primary)
                            } else {
                                Circle()
                                    .stroke(SanchrExportColors.line, lineWidth: 2)
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)

                    if index < options.count - 1 {
                        Rectangle()
                            .fill(SanchrExportColors.line)
                            .frame(height: 1)
                            .padding(.leading, 72)
                    }
                }
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Disappearing Messages")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedDuration = Int(
                DisappearingTimerStore.getDuration(conversationId: conversationId)
            )
        }
    }
}

// MARK: - VaultMediaView

private struct VaultMediaView: View {
    let conversationId: String

    @Environment(DependencyContainer.self) private var container
    @State private var policy: ChatVaultPolicy
    @State private var isLoading: Bool = true

    init(conversationId: String) {
        self.conversationId = conversationId
        self._policy = State(initialValue: .defaults(for: conversationId))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Info banner
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrColors.primaryDark)
                        .padding(.top, 2)
                    Text(
                        "Vault media is encrypted at rest, can self-destruct after viewing, and is hidden during screen recording or mirroring. Screenshots can still trigger an alert."
                    )
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrExportColors.textSecondary)
                }
                .padding(16)
                .background(
                    LinearGradient(
                        colors: [
                            SanchrColors.primaryDark.opacity(0.05),
                            SanchrColors.primary.opacity(0.05),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                vaultToggle(
                    icon: "tray.and.arrow.down.fill",
                    title: "Auto-Vault Incoming",
                    subtitle: "Automatically protect received media in this chat",
                    isOn: Binding(
                        get: { policy.autoVaultIncoming },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: newValue,
                                viewOnceOutgoing: policy.viewOnceOutgoing,
                                screenshotProtection: policy.screenshotProtection
                            )
                            persist()
                        }
                    )
                )

                Rectangle().fill(SanchrExportColors.line).frame(height: 1).padding(.leading, 72)

                vaultToggle(
                    icon: "eye.fill",
                    title: "View Once",
                    subtitle: "Media you send disappears after the recipient views it",
                    isOn: Binding(
                        get: { policy.viewOnceOutgoing },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: policy.autoVaultIncoming,
                                viewOnceOutgoing: newValue,
                                screenshotProtection: policy.screenshotProtection
                            )
                            persist()
                        }
                    )
                )

                Rectangle().fill(SanchrExportColors.line).frame(height: 1).padding(.leading, 72)

                vaultToggle(
                    icon: "camera.metering.none",
                    title: "Capture Protection",
                    subtitle: "Hide vault media during screen recording or mirroring, and notify the other person if you take a screenshot",
                    isOn: Binding(
                        get: { policy.screenshotProtection },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: policy.autoVaultIncoming,
                                viewOnceOutgoing: policy.viewOnceOutgoing,
                                screenshotProtection: newValue
                            )
                            persist()
                        }
                    )
                )
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Vault Media")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await container.chatVaultPolicy.loadPolicy(conversationId: conversationId)
            policy = container.chatVaultPolicy.effectivePolicy(for: conversationId)
            isLoading = false
        }
    }

    private func persist() {
        Task {
            await container.chatVaultPolicy.setPolicy(policy)
        }
    }

    private func vaultToggle(icon: String, title: String, subtitle: String, isOn: Binding<Bool>)
        -> some View
    {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceSoft)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
    }
}

// MARK: - Inline media-section helpers

private struct ConversationInfoGalleryPresentation: Identifiable {
    let id = UUID()
    let items: [Message]
    let initialIndex: Int
}

private struct ConversationInfoMediaThumbnail: View {
    let message: Message
    let resolver: ChatMediaResolving

    @State private var image: UIImage?

    var body: some View {
        // GeometryReader pins the image to the cell's actual bounds so
        // .scaledToFill has a frame to fill instead of overflowing the
        // RoundedRectangle clip. The outer aspectRatio gives the
        // GeometryReader a square layout slot.
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(SanchrExportColors.surfaceSoft)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 3)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: message.id) {
            await loadThumbnail()
        }
    }

    private var isVideo: Bool {
        if case .video = message.content { return true }
        return false
    }

    private func loadThumbnail() async {
        guard let attachment = Self.attachment(for: message) else { return }
        do {
            let url = try await resolver.decryptedURL(
                forMessageId: message.id,
                attachment: attachment
            )
            let loaded: UIImage?
            if isVideo {
                loaded = await MediaThumbnailGenerator.posterFrame(forVideoAt: url)
            } else {
                loaded = UIImage(contentsOfFile: url.path)
            }
            if let loaded {
                await MainActor.run { self.image = loaded }
            }
        } catch {
            // Silent: leave the placeholder rectangle.
        }
    }

    private static func attachment(for message: Message) -> Message.MediaAttachment? {
        switch message.content {
        case .image(let a), .video(let a): return a
        default: return nil
        }
    }
}

/// Off-main poster-frame generator. Used by inline media thumbnails
/// in ConversationInfoView and the Media tab in SharedContentView so
/// they don't blindly hand a video file to UIImage(contentsOfFile:)
/// (which dumps "createImageAtIndex... could not find plugin" errors
/// to the console for every MP4 in the chat).
enum MediaThumbnailGenerator {
    static func posterFrame(forVideoAt url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                return UIImage(cgImage: cgImage)
            } catch {
                return nil
            }
        }.value
    }
}
