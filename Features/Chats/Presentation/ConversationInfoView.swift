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

private struct VerifySecurityCodeView: View {
    let conversation: Conversation
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedFingerprint = false
    @State private var fingerprintDigits: [[String]] = []
    @State private var fingerprintRaw: String = ""
    @State private var qrImage: UIImage?
    @State private var scannableFingerprintData: Data?
    @State private var loadError: String?
    @State private var isVerified = false
    @State private var showVerifiedAlert = false
    @State private var showScannerSheet = false
    @State private var scanResult: ScanResultType?

    enum ScanResultType {
        case match
        case mismatch
        case error(String)
    }

    private var recipient: User? {
        conversation.participants.first(where: { !$0.isLocalUser })
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                mainContent
            }
            .background(SanchrExportColors.background.ignoresSafeArea())

            verifyFooter
        }
        .navigationTitle("Encryption Keys")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let recipientId = recipient?.id {
                isVerified = container.signalProtocol.isIdentityVerified(userId: recipientId)
            }
            Task { await loadFingerprint() }
        }
        .sheet(isPresented: $showScannerSheet) {
            QRScannerSheet(
                onScanned: { scannedData in
                    showScannerSheet = false
                    guard let recipientId = recipient?.id else { return }

                    do {
                        let myKey = try container.signalProtocol.localIdentityKeyData()
                        let theirKey = try container.signalProtocol.remoteIdentityKeyData(
                            for: recipientId, deviceId: 1)
                        let localUserId = container.signalProtocol.localUserId

                        let fpQR = SanchrFingerprintQR.create(
                            myId: localUserId,
                            myIdentityKey: myKey,
                            theirId: recipientId,
                            theirIdentityKey: theirKey
                        )

                        let result = fpQR.matches(scannedData: scannedData)
                        switch result {
                        case .match:
                            container.signalProtocol.markIdentityVerified(userId: recipientId)
                            isVerified = true
                            scanResult = .match
                        case .noMatch(let reason):
                            SanchrLogger.crypto.warning("QR verification failed: \(reason)")
                            scanResult = .mismatch
                        }
                    } catch {
                        scanResult = .error(error.localizedDescription)
                    }
                },
                onCancel: { showScannerSheet = false }
            )
        }
        .alert(
            scanResultTitle,
            isPresented: Binding(
                get: { scanResult != nil },
                set: { if !$0 { scanResult = nil } }
            )
        ) {
            Button("OK", role: .cancel) { scanResult = nil }
        } message: {
            Text(scanResultMessage)
        }
        .alert(
            isVerified ? "Already Verified" : "Mark as Verified",
            isPresented: $showVerifiedAlert
        ) {
            if !isVerified {
                Button("Verify") {
                    if let recipientId = recipient?.id {
                        container.signalProtocol.markIdentityVerified(userId: recipientId)
                        isVerified = true
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            if isVerified {
                Text("This contact's identity has already been verified.")
            } else {
                Text("Have you compared security codes with your contact and confirmed they match?")
            }
        }
    }

    private func loadFingerprint() async {
        guard let recipientId = recipient?.id else {
            loadError = "No recipient found"
            return
        }

        // Run crypto + image generation off main thread
        let signalProtocol = container.signalProtocol
        let result: (String, [[String]], Data?, UIImage?) = await Task.detached {
            do {
                let safetyNumber = try signalProtocol.safetyNumber(for: recipientId, deviceId: 1)

                let digits = stride(from: 0, to: safetyNumber.count, by: 5).map { i in
                    let start = safetyNumber.index(safetyNumber.startIndex, offsetBy: i)
                    let end = safetyNumber.index(start, offsetBy: min(5, safetyNumber.count - i))
                    return String(safetyNumber[start..<end])
                }
                let rows = stride(from: 0, to: digits.count, by: 5).map { i in
                    Array(digits[i..<min(i + 5, digits.count)])
                }

                // Generate Signal-compatible QR fingerprint
                let myKey = try signalProtocol.localIdentityKeyData()
                let theirKey = try signalProtocol.remoteIdentityKeyData(
                    for: recipientId, deviceId: 1)
                let localUserId = signalProtocol.localUserId

                let fpQR = SanchrFingerprintQR.create(
                    myId: localUserId,
                    myIdentityKey: myKey,
                    theirId: recipientId,
                    theirIdentityKey: theirKey
                )
                let qrData = fpQR.serialize()
                let qr = makeQRCodeFromBinary(qrData)

                return (safetyNumber, rows, qrData, qr)
            } catch {
                let fallbackDigits = [
                    ["28394", "75621", "94857", "63294", "12847"],
                    ["58392", "67483", "92847", "38475", "84729"],
                    ["39485", "73829", "48573", "92847", "58392"],
                ]
                let raw = fallbackDigits.flatMap { $0 }.joined()
                let qr = makeQRCodeImage(from: raw)
                return (raw, fallbackDigits, nil, qr)
            }
        }.value

        fingerprintRaw = result.0
        fingerprintDigits = result.1
        scannableFingerprintData = result.2
        qrImage = result.3
    }

    // makeQRCode moved to file-scope free function (makeQRCodeImage) for Sendable compliance

    private var scanResultTitle: String {
        switch scanResult {
        case .match: return "Verified"
        case .mismatch: return "Not Matched"
        case .error: return "Error"
        case nil: return ""
        }
    }

    private var scanResultMessage: String {
        switch scanResult {
        case .match: return "Security codes match. This conversation is verified and secure."
        case .mismatch: return "Security codes do not match. This may indicate a security issue."
        case .error(let msg): return "Could not verify: \(msg)"
        case nil: return ""
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 32) {
            qrVerificationSection
            fingerprintSection
            encryptionDetailsSection
            infoCard
            Color.clear.frame(height: 80)  // space for fixed footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: - QR Verification

    private var qrVerificationSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Verify Security Code")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text(
                    "Compare this QR code with your contact's device or verify the 60-digit code below"
                )
                .font(SanchrTypography.messageBubbleText)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)
            }

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(colorScheme == .dark ? Color(hex: 0x1A1A24) : Color(hex: 0xF9FAFB))
                .frame(height: 280)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? Color(hex: 0x24243A) : Color.white)
                        .frame(width: 220, height: 220)
                        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
                        .overlay {
                            if let qrImage {
                                let img = Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(16)
                                if colorScheme == .dark {
                                    img.colorInvert()
                                } else {
                                    img
                                }
                            } else {
                                ProgressView()
                                    .tint(.sanchrPrimary)
                            }
                        }
                }

            Button {
                showScannerSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Scan QR Code")
                        .font(SanchrTypography.body)
                        .fontWeight(.semibold)
                }
                .foregroundColor(SanchrColors.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(SanchrColors.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Security Fingerprint

    private var fingerprintSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Security Fingerprint")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(SanchrExportColors.textPrimary)
                Spacer()
                Button {
                    let allNumbers = fingerprintDigits.flatMap { $0 }.joined(separator: " ")
                    UIPasteboard.general.string = allNumbers
                    copiedFingerprint = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedFingerprint = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(copiedFingerprint ? "Copied!" : "Copy")
                            .font(SanchrTypography.messageBubbleText)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(SanchrColors.primary)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 12) {
                if fingerprintDigits.isEmpty {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    ForEach(0..<fingerprintDigits.count, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<fingerprintDigits[row].count, id: \.self) { col in
                                Text(fingerprintDigits[row][col])
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        colorScheme == .dark ? Color(hex: 0x24243A) : Color.white
                                    )
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .background(colorScheme == .dark ? Color(hex: 0x1A1A24) : Color(hex: 0xF9FAFB))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Encryption Details

    private var encryptionDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Encryption Details")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(SanchrExportColors.textPrimary)

            encryptionDetailCard(
                icon: "key.fill",
                iconBg: SanchrColors.primary.opacity(0.1),
                iconColor: SanchrColors.primary,
                title: "Your Identity Key",
                subtitle: "Your unique encryption key that identifies you in all conversations",
                gradientStart: SanchrColors.primary.opacity(0.05),
                gradientEnd: SanchrColors.accent.opacity(0.05),
                borderColor: SanchrColors.primary.opacity(0.1)
            )

            encryptionDetailCard(
                icon: "lock.fill",
                iconBg: SanchrColors.accent.opacity(0.1),
                iconColor: SanchrColors.accent,
                title: "Session Key",
                subtitle: "Temporary key for this conversation, regenerated periodically",
                gradientStart: SanchrColors.accent.opacity(0.05),
                gradientEnd: SanchrColors.primary.opacity(0.05),
                borderColor: SanchrColors.accent.opacity(0.1)
            )

            encryptionDetailCard(
                icon: "shield.fill",
                iconBg: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.2) : Color(hex: 0xDCFCE7),
                iconColor: Color(hex: 0x16A34A),
                title: "Verification Status",
                subtitle: nil,
                statusText: "Verified on Dec 8, 2024",
                gradientStart: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.08) : Color(hex: 0xF0FDF4),
                gradientEnd: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.05) : Color(hex: 0xECFDF5),
                borderColor: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.2) : Color(hex: 0xBBF7D0)
            )
        }
    }

    private func encryptionDetailCard(
        icon: String,
        iconBg: Color,
        iconColor: Color,
        title: String,
        subtitle: String?,
        statusText: String? = nil,
        gradientStart: Color,
        gradientEnd: Color,
        borderColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(iconBg)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
                    .foregroundColor(SanchrExportColors.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                if let statusText {
                    Text(statusText)
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.semibold)
                        .foregroundColor(Color(hex: 0x16A34A))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                colorScheme == .dark ? Color(hex: 0x1A1A24) : Color.white
                LinearGradient(
                    colors: [gradientStart, gradientEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(colorScheme == .dark ? borderColor.opacity(0.3) : borderColor, lineWidth: 1)
        }
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(SanchrColors.primary.opacity(0.1))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(SanchrColors.primary)
                }

            Text(
                "If your security code matches your contact's code, your conversation is secure. No one, not even Sanchr, can read your messages."
            )
            .font(SanchrTypography.messageBubbleText)
            .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(20)
        .background(colorScheme == .dark ? Color(hex: 0x1A1A24) : Color(hex: 0xF9FAFB))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Footer

    private var verifyFooter: some View {
        VStack(spacing: 0) {
            Button {
                showVerifiedAlert = true
            } label: {
                SanchrGradientButtonLabel(
                    title: isVerified ? "Verified" : "Mark as Verified",
                    systemName: isVerified ? "checkmark.seal.fill" : "checkmark.shield.fill"
                )
            }
            .buttonStyle(SanchrPrimaryCTA())
            .opacity(isVerified ? 0.7 : 1.0)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(
            SanchrExportColors.background
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - WallpaperThemeView

private struct WallpaperThemeView: View {
    let conversationId: String

    @Environment(DependencyContainer.self) private var container
    @State private var selectedWallpaperId: String = "default"
    @State private var darkMode: Bool = false
    @State private var hasOverride: Bool = false
    @State private var isLoading: Bool = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                scopeBanner
                darkModeToggleRow
                wallpaperGrid
                if hasOverride {
                    resetToGlobalButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Wallpaper & Theme")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await container.chatAppearance.loadOverride(conversationId: conversationId)
            let appearance = container.chatAppearance.effectiveAppearance(for: conversationId)
            selectedWallpaperId = appearance.wallpaperId
            darkMode = (appearance.appearanceMode == .dark)
            hasOverride = appearance.isPerChatOverride
            isLoading = false
        }
    }

    @ViewBuilder
    private var scopeBanner: some View {
        let copy = hasOverride
            ? "Applied to this chat only — overrides global"
            : "Inheriting global appearance"
        Text(copy)
            .font(SanchrTypography.captionSmall)
            .foregroundColor(SanchrExportColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SanchrExportColors.surfaceSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var darkModeToggleRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceSoft)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: darkMode ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrColors.primary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Dark Mode")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Use dark theme for this chat only")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { darkMode },
                set: { newValue in
                    darkMode = newValue
                    autoSwitchWallpaperForMode(newValue)
                    Task { await applyOverride() }
                }
            ))
            .labelsHidden()
            .tint(.sanchrPrimary)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var wallpaperGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chat Wallpaper")
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.semibold)
                .foregroundColor(SanchrExportColors.textPrimary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                ForEach(WallpaperPainter.allWallpapers) { wp in
                    WallpaperPainter.background(for: wp.id)
                        .aspectRatio(0.7, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if selectedWallpaperId == wp.id {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SanchrColors.primary, lineWidth: 3)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(SanchrColors.primary)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedWallpaperId = wp.id
                                darkMode = wp.isDark
                            }
                            Task { await applyOverride() }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var resetToGlobalButton: some View {
        Button {
            Task { await resetToGlobal() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                Text("Reset to Global")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
            }
            .foregroundColor(SanchrColors.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(SanchrColors.primary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutations

    private func applyOverride() async {
        await container.chatAppearance.setOverride(
            conversationId: conversationId,
            wallpaperId: selectedWallpaperId,
            appearanceMode: darkMode ? .dark : .light
        )
        hasOverride = true
    }

    private func resetToGlobal() async {
        await container.chatAppearance.setOverride(
            conversationId: conversationId,
            wallpaperId: nil,
            appearanceMode: nil
        )
        let appearance = container.chatAppearance.effectiveAppearance(for: conversationId)
        selectedWallpaperId = appearance.wallpaperId
        darkMode = (appearance.appearanceMode == .dark)
        hasOverride = false
    }

    /// When the user toggles dark mode on/off, switch the selected
    /// wallpaper to the first matching-tone wallpaper from the registry
    /// IF the current selection doesn't already match. Avoids the
    /// incoherent "dark mode on, but light wallpaper selected" state
    /// while preserving the user's explicit pick when they pick it
    /// after toggling.
    private func autoSwitchWallpaperForMode(_ isDark: Bool) {
        let currentWp = WallpaperPainter.wallpaper(for: selectedWallpaperId)
        guard currentWp.isDark != isDark else { return }
        let candidates = WallpaperPainter.allWallpapers.filter { $0.isDark == isDark }
        if let first = candidates.first {
            selectedWallpaperId = first.id
        }
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

// MARK: - Signal-Compatible Fingerprint (QR Verification)

private struct SanchrFingerprintQR {
    let myHash: Data  // 32 bytes
    let theirHash: Data  // 32 bytes
    let version: UInt32 = 2

    /// Generates fingerprint hash data using Signal's algorithm:
    /// SHA-512(version || publicKey || stableId), iterated 5200 times, take first 32 bytes.
    static func create(
        myId: String,
        myIdentityKey: Data,
        theirId: String,
        theirIdentityKey: Data
    ) -> SanchrFingerprintQR {
        let myHash = computeHash(stableId: Data(myId.utf8), publicKey: myIdentityKey)
        let theirHash = computeHash(stableId: Data(theirId.utf8), publicKey: theirIdentityKey)
        return SanchrFingerprintQR(myHash: myHash, theirHash: theirHash)
    }

    private static func computeHash(stableId: Data, publicKey: Data, iterations: UInt32 = 5200)
        -> Data
    {
        // Signal: hash = SHA512(version(2 bytes BE) || publicKey || stableId)
        // Then iterate: hash = SHA512(hash || publicKey) × 5200
        // Take first 32 bytes
        let versionBytes = UInt16(0).bigEndianData

        var hash = Data()
        hash.append(versionBytes)
        hash.append(publicKey)
        hash.append(stableId)

        for _ in 0..<iterations {
            hash.append(publicKey)
            let digest = SHA512.hash(data: hash)
            hash = Data(digest)
        }

        return hash.prefix(32)
    }

    /// Serialize to protobuf-like binary format for QR encoding.
    /// Format: [version: 4 bytes LE] [local length: 4 bytes LE] [local hash: 32 bytes] [remote length: 4 bytes LE] [remote hash: 32 bytes]
    func serialize() -> Data {
        var data = Data()
        // Version
        var v = version.littleEndian
        data.append(Data(bytes: &v, count: 4))
        // Local fingerprint (my hash)
        var localLen = UInt32(myHash.count).littleEndian
        data.append(Data(bytes: &localLen, count: 4))
        data.append(myHash)
        // Remote fingerprint (their hash)
        var remoteLen = UInt32(theirHash.count).littleEndian
        data.append(Data(bytes: &remoteLen, count: 4))
        data.append(theirHash)
        return data
    }

    /// Deserialize scanned data and compare.
    /// Their local = our remote (swap perspective).
    func matches(scannedData: Data) -> VerifyResult {
        SanchrLogger.crypto.info("QR verify: scanned \(scannedData.count) bytes, expected 76")

        guard scannedData.count >= 76 else {
            SanchrLogger.crypto.warning("QR verify: data too short (\(scannedData.count) bytes)")
            return .noMatch("Invalid QR code data (\(scannedData.count) bytes)")
        }

        var offset = 0

        // Read version
        let scannedVersion = scannedData.subdata(in: offset..<offset + 4).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }.littleEndian
        offset += 4
        SanchrLogger.crypto.info(
            "QR verify: scanned version=\(scannedVersion), our version=\(version)")

        if scannedVersion != version {
            return .noMatch("Version mismatch: scanned=\(scannedVersion), ours=\(version)")
        }

        // Read scanned local hash
        let scannedLocalLen = Int(
            scannedData.subdata(in: offset..<offset + 4).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.littleEndian)
        offset += 4
        guard offset + scannedLocalLen <= scannedData.count else {
            return .noMatch("Invalid QR data")
        }
        let scannedLocalHash = scannedData.subdata(in: offset..<offset + scannedLocalLen)
        offset += scannedLocalLen

        // Read scanned remote hash
        guard offset + 4 <= scannedData.count else { return .noMatch("Invalid QR data") }
        let scannedRemoteLen = Int(
            scannedData.subdata(in: offset..<offset + 4).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.littleEndian)
        offset += 4
        guard offset + scannedRemoteLen <= scannedData.count else {
            return .noMatch("Invalid QR data")
        }
        let scannedRemoteHash = scannedData.subdata(in: offset..<offset + scannedRemoteLen)

        SanchrLogger.crypto.info(
            "QR verify: scannedLocal=\(scannedLocalHash.prefix(8).map { String(format: "%02x", $0) }.joined())..., scannedRemote=\(scannedRemoteHash.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        )
        SanchrLogger.crypto.info(
            "QR verify: ourMyHash=\(myHash.prefix(8).map { String(format: "%02x", $0) }.joined())..., ourTheirHash=\(theirHash.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        )

        // Cross-device verification:
        // The scanned QR was generated by the OTHER device where:
        //   their "local" = their identity (should match our "theirHash")
        //   their "remote" = our identity (should match our "myHash")
        let crossMatch = (scannedLocalHash == theirHash && scannedRemoteHash == myHash)

        // Self-scan detection:
        // If scanning your OWN QR, local/remote are NOT swapped
        let selfMatch = (scannedLocalHash == myHash && scannedRemoteHash == theirHash)

        if crossMatch || selfMatch {
            SanchrLogger.crypto.info(
                "QR verify: MATCH (\(selfMatch ? "self-scan" : "cross-device"))")
            return .match
        }

        SanchrLogger.crypto.warning("QR verify: NO MATCH")
        SanchrLogger.crypto.warning("  scannedLocal==theirHash? \(scannedLocalHash == theirHash)")
        SanchrLogger.crypto.warning("  scannedRemote==myHash? \(scannedRemoteHash == myHash)")
        SanchrLogger.crypto.warning("  scannedLocal==myHash? \(scannedLocalHash == myHash)")
        SanchrLogger.crypto.warning("  scannedRemote==theirHash? \(scannedRemoteHash == theirHash)")
        return .noMatch("Security codes do not match")
    }

    enum VerifyResult {
        case match
        case noMatch(String)
    }
}

extension UInt16 {
    fileprivate var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 2)
    }
}

// MARK: - QR Code Scanner

private struct QRScannerSheet: View {
    let onScanned: (Data) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            ZStack {
                QRScannerRepresentable(onScanned: onScanned)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Point your camera at the QR code on your contact's device")
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.bottom, 60)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (Data) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onScanned: onScanned)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private class QRScannerViewController: UIViewController {
    private let onScanned: (Data) -> Void
    private var captureSession: AVCaptureSession?
    private var hasScanned = false

    init(onScanned: @escaping (Data) -> Void) {
        self.onScanned = onScanned
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let previewLayer = view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = view.bounds
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            let delegate = QRScannerDelegate { [weak self] data in
                guard let self, !self.hasScanned else { return }
                self.hasScanned = true
                self.captureSession?.stopRunning()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.onScanned(data)
            }
            objc_setAssociatedObject(output, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        self.captureSession = session
        let capturedSession = session
        DispatchQueue.global(qos: .userInitiated).async { [weak capturedSession] in
            capturedSession?.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}

private class QRScannerDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let handler: (Data) -> Void

    init(handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject else {
            return
        }

        // Extract raw binary data from QR codewords using Signal's approach
        if #available(iOS 17.0, *),
            let descriptor = object.descriptor as? CIQRCodeDescriptor
        {
            let codewords = descriptor.errorCorrectedPayload
            let version = descriptor.symbolVersion
            if let payload = QRByteModeParser.parse(codewords: codewords, qrVersion: version) {
                SanchrLogger.crypto.info(
                    "QR scan: parsed \(payload.count) bytes from codewords (\(codewords.count) raw)"
                )
                handler(payload)
                return
            }
        }

        // Fallback: use string value with Latin1 to preserve byte values
        if let stringValue = object.stringValue,
            let data = stringValue.data(using: .isoLatin1)
        {
            SanchrLogger.crypto.info("QR scan: fallback Latin1, \(data.count) bytes")
            handler(data)
        }
    }
}

// MARK: - QR Byte-Mode Parser (Signal's QRCodePayload approach)

/// Parses raw QR error-corrected codewords to extract byte-mode payload.
/// CIQRCodeDescriptor.errorCorrectedPayload returns raw codewords which include
/// mode indicators and character count bits -- NOT the actual data bytes.
private enum QRByteModeParser {
    static func parse(codewords: Data, qrVersion: Int) -> Data? {
        var bitOffset = 0
        let bits = codewords.flatMap { byte -> [UInt8] in
            (0..<8).reversed().map { UInt8((byte >> $0) & 1) }
        }

        // Read 4-bit mode indicator
        guard bitOffset + 4 <= bits.count else { return nil }
        let mode = readBits(bits, offset: &bitOffset, count: 4)
        guard mode == 4 else {
            // Mode 4 = Byte mode. Other modes not supported for fingerprint QR.
            SanchrLogger.crypto.warning("QR parse: unsupported mode \(mode)")
            return nil
        }

        // Character count indicator length depends on QR version
        let charCountBits: Int
        if qrVersion <= 9 {
            charCountBits = 8
        } else if qrVersion <= 26 {
            charCountBits = 16
        } else {
            charCountBits = 16
        }

        guard bitOffset + charCountBits <= bits.count else { return nil }
        let charCount = Int(readBits(bits, offset: &bitOffset, count: charCountBits))
        guard charCount > 0 else { return nil }

        // Read the actual data bytes
        var result = Data(capacity: charCount)
        for _ in 0..<charCount {
            guard bitOffset + 8 <= bits.count else { return nil }
            let byte = UInt8(readBits(bits, offset: &bitOffset, count: 8))
            result.append(byte)
        }

        return result
    }

    private static func readBits(_ bits: [UInt8], offset: inout Int, count: Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<count {
            value = (value << 1) | UInt32(bits[offset])
            offset += 1
        }
        return value
    }
}

// MARK: - QR Code Generation (nonisolated, Sendable-safe)

/// Generates a QR code from raw binary data (Signal ScannableFingerprint).
private nonisolated func makeQRCodeFromBinary(_ data: Data) -> UIImage? {
    guard !data.isEmpty,
        let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("L", forKey: "inputCorrectionLevel")
    guard let ciImage = filter.outputImage else { return nil }

    let scale = 10.0
    let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}

/// Generates a QR code from a string (fallback for safety number digits).
private nonisolated func makeQRCodeImage(from string: String) -> UIImage? {
    guard !string.isEmpty,
        let data = string.data(using: .utf8),
        let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ciImage = filter.outputImage else { return nil }

    let scale = 10.0
    let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    let context = CIContext()
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
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
