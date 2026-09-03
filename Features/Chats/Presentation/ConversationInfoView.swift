@preconcurrency import AVFoundation
import Contacts
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
    @State private var exportedTranscript: ExportedTranscript?
    @State private var showClearChat = false
    @State private var showBlockContact = false
    @State private var conversationActionErrorMessage: String?
    @State private var isPeerInDeviceContacts = false
    @State private var showAddToDeviceContacts = false

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

    // MARK: - Add to Device Contacts

    /// The name to prefill the new-contact sheet with. Strips the "~" untrusted
    /// marker the list adds to profile names, and rejects the server placeholder,
    /// a bare user id, and the "Unknown contact" fallback — none of which are a
    /// name worth saving to the address book.
    private var contactPrefillName: String? {
        let raw = (activeRecipient?.displayName ?? conversation.displayName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name =
            raw.hasPrefix("~")
            ? String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
            : raw
        guard !name.isEmpty,
            name != User.serverPlaceholderDisplayName,
            name != "Unknown contact",
            UUID(uuidString: name) == nil
        else { return nil }
        return name
    }

    private var contactPrefillPhone: String {
        activeRecipient?.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Offer "Add to Contacts" only for a 1:1 peer who isn't already in the device
    /// address book and for whom we have something worth saving (a real name or a
    /// phone number).
    private var canAddPeerToDeviceContacts: Bool {
        guard conversation.type == .oneToOne, !isPeerInDeviceContacts else { return false }
        return contactPrefillName != nil || !contactPrefillPhone.isEmpty
    }

    /// Checks whether the peer is already in the device address book. Only a
    /// phone number can be matched, and only when read access is already granted
    /// — we never prompt for Contacts access just to decide whether to show the
    /// button. When we can't tell, we default to offering it (adding a duplicate
    /// is recoverable; hiding the option when it's needed is not).
    private func refreshDeviceContactMembership() async {
        // A peer we saved earlier through this screen stays hidden — a
        // name-only QR peer has no phone number to match against the address
        // book, so we remember the add ourselves rather than re-deriving it.
        if let id = activeRecipient?.id, Self.wasAddedToDeviceContacts(id) {
            isPeerInDeviceContacts = true
            return
        }
        let phone = contactPrefillPhone
        guard !phone.isEmpty,
            CNContactStore.authorizationStatus(for: .contacts) == .authorized
        else {
            isPeerInDeviceContacts = false
            return
        }
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
        let matches =
            (try? store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
        isPeerInDeviceContacts = !matches.isEmpty
    }

    // Records, per peer id, that the user saved them to the device address book,
    // so the "Add to Contacts" row does not keep offering an already-saved peer.
    private static let deviceContactsAddedKey = "sanchr.deviceContactsAdded"

    private static func wasAddedToDeviceContacts(_ userId: String) -> Bool {
        (UserDefaults.standard.array(forKey: deviceContactsAddedKey) as? [String] ?? [])
            .contains(userId)
    }

    private static func markAddedToDeviceContacts(_ userId: String) {
        var ids = UserDefaults.standard.array(forKey: deviceContactsAddedKey) as? [String] ?? []
        guard !ids.contains(userId) else { return }
        ids.append(userId)
        UserDefaults.standard.set(ids, forKey: deviceContactsAddedKey)
    }

    @ViewBuilder
    private var addToContactsSection: some View {
        if canAddPeerToDeviceContacts {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showAddToDeviceContacts = true
                } label: {
                    settingsRow(
                        icon: "person.crop.circle.badge.plus",
                        iconBg: SanchrExportColors.surfaceSoft,
                        iconColor: SanchrColors.accent,
                        title: "Add to Contacts",
                        subtitle: "Save this person to your device address book"
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
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                profileSection
                addToContactsSection
                mediaSection
                securitySection
                chatPreferencesSection
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
        .task(id: contactPrefillPhone) {
            // Re-check once the server refresh fills in the phone number.
            await refreshDeviceContactMembership()
        }
        .sheet(isPresented: $showAddToDeviceContacts) {
            ContactViewControllerHost(
                mode: .newContact(name: contactPrefillName ?? "", phone: contactPrefillPhone),
                onDismiss: {
                    showAddToDeviceContacts = false
                    Task { await refreshDeviceContactMembership() }
                },
                onSaved: {
                    if let id = activeRecipient?.id { Self.markAddedToDeviceContacts(id) }
                    isPeerInDeviceContacts = true
                }
            )
            .ignoresSafeArea()
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
            Button("Export Transcript") {
                Task { await exportTranscript() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Only the text transcript. There was previously an "Export with
            // Media" option that did nothing; offering it again would mean
            // bundling and re-encrypting every attachment, which this does not do.
            Text("Saves the message text of this conversation. Media is not included.")
        }
        .sheet(item: $exportedTranscript) { payload in
            ShareSheet(items: [payload.url])
        }
        .alert("Clear Chat", isPresented: $showClearChat) {
            Button("Clear All Messages", role: .destructive) {
                Task { await clearAllMessages() }
            }
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
                        container.privacySettings.setBlocked(userId, true)
                        SanchrLogger.sync.info("Blocked contact \(userId.prefix(8))… from ConversationInfo")
                        dismiss()
                    } catch {
                        // Every other action on this screen reports its failures;
                        // block silently swallowed them, so a block that never
                        // reached the server looked identical to one that
                        // succeeded. People block someone when they feel unsafe —
                        // believing it worked when it did not is the worst
                        // possible outcome here, so say so and stay on screen.
                        conversationActionErrorMessage =
                            "Couldn't block this contact: \(error.localizedDescription)"
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
                .sanchrShadow(0.12, radius: 12, y: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName)
                    .font(SanchrTypography.font(size: .lg, weight: .bold))
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

    /// Deletes every message in this conversation and wipes any cached media.
    ///
    /// The dialog promises permanent deletion, so this removes the rows and the
    /// decrypted files rather than hiding them — an attachment surviving its
    /// message would leave exactly what the user asked to be gone.
    private func clearAllMessages() async {
        do {
            let ids = try await container.localDatabase.deleteAllMessages(
                conversationId: conversation.id)
            for id in ids {
                await container.mediaDownloadManager.removeCachedFile(messageId: id)
            }
            await MainActor.run {
                NotificationCenter.default.postConversationStateDidChange(
                    conversationId: conversation.id)
            }
            SanchrLogger.chat.info("Cleared \(ids.count) message(s) from \(conversation.id.prefix(8))")
        } catch {
            conversationActionErrorMessage = UserFacingError.message(for: error)
            SanchrLogger.chat.error("Clear chat failed: \(error.localizedDescription)")
        }
    }

    /// Writes the conversation's message text to a file and offers it via the
    /// share sheet. Text only — media is deliberately excluded.
    private func exportTranscript() async {
        do {
            let messages = try await container.localDatabase.fetchMessages(
                conversationId: conversation.id, before: nil, limit: 10_000)
            guard !messages.isEmpty else {
                conversationActionErrorMessage = "There are no messages to export."
                return
            }

            let localUserId = container.signalProtocol.localUserId
            let peerName = recipient?.displayName ?? "Unknown"
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH:mm"

            var lines = ["Sanchr conversation with \(peerName)",
                         "Exported \(stamp.string(from: Date()))",
                         "Text only — media is not included.",
                         ""]
            for message in messages {
                let who = message.senderId == localUserId ? "You" : peerName
                lines.append("[\(stamp.string(from: message.timestamp))] \(who): \(Self.transcriptLine(for: message))")
            }

            // Written to the temporary directory so it is not left in a
            // user-visible container after the share sheet closes.
            let safeName = peerName.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Sanchr-\(safeName).txt")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

            exportedTranscript = ExportedTranscript(url: url)
        } catch {
            conversationActionErrorMessage = UserFacingError.message(for: error)
            SanchrLogger.chat.error("Export failed: \(error.localizedDescription)")
        }
    }

    /// Attachments are described rather than embedded, so an export never
    /// contains media the user was told it would not include.
    private static func transcriptLine(for message: Message) -> String {
        switch message.content {
        case .text(let text): return text
        case .image: return "[photo]"
        case .video: return "[video]"
        case .audio: return "[audio]"
        case .document(let media): return "[document: \(media.first?.filename ?? "file")]"
        case .location: return "[location]"
        case .contact(let name, _): return "[contact: \(name)]"
        case .system(let event): return "[\(event.displayLabel)]"
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
            conversationActionErrorMessage = UserFacingError.message(for: error)
        }
    }

    @MainActor
    private func hideConversationFromDevice() async {
        do {
            try await container.messageRepository.hideConversationLocally(conversationId: conversation.id)
            dismiss()
        } catch {
            conversationActionErrorMessage = UserFacingError.message(for: error)
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
            conversationActionErrorMessage = UserFacingError.message(for: error)
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

/// Identifiable wrapper so the export share sheet can be presented with `.sheet(item:)`.
struct ExportedTranscript: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Presents the system share sheet for an exported transcript.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
