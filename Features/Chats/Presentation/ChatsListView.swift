import AVFoundation
import Kingfisher
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import SanchrShared

private struct PendingHomeMediaSelection: Identifiable {
    let id = UUID()
    let intent: AttachmentIntent
}

struct ChatsListView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @State private var viewModel = ChatsListViewModel()
    @State private var showNewConversation = false
    @State private var showHomeMediaOptions = false
    @State private var showHomeCameraCapture = false
    @State private var showHomePhotoLibrary = false
    @State private var selectedHomePhotoItems: [PhotosPickerItem] = []
    @State private var pendingHomeMediaSelection: PendingHomeMediaSelection?
    @State private var isPreparingHomeMedia = false
    @State private var homeMediaLoadErrorMessage: String?
    @State private var showArchivedChats = false
    @State private var showHiddenChats = false
    @State private var conversationToDelete: Conversation?
    @State private var sanchrModeEnabled = false

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }
    @State private var pendingConversationRefreshIDs: Set<String> = []
    @State private var scheduledRefreshTask: Task<Void, Never>?
    @State private var trackedPresencePeerIds: Set<String> = []

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            mainContent
            fabButton
        }
        .navigationBarHidden(true)
        .sanchrInteractivePopEnabled()
        .navigationDestination(for: Conversation.self) { conversation in
            ChatDetailView(conversation: conversation)
        }
        .confirmationDialog(
            "Delete Conversation",
            isPresented: Binding(
                get: { conversationToDelete != nil },
                set: { if !$0 { conversationToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let conversation = conversationToDelete {
                    Task {
                        await viewModel.deleteConversation(
                            conversation,
                            messageRepository: container.messageRepository,
                            chatDataSource: container.chatDataSource
                        )
                    }
                }
                conversationToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
        }
        .confirmationDialog("Add Media", isPresented: $showHomeMediaOptions, titleVisibility: .visible) {
            Button("Camera") {
                showHomeCameraCapture = true
            }

            Button("Photo Library") {
                showHomePhotoLibrary = true
            }

            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showHomeCameraCapture) {
            CameraCaptureView(
                onCapture: { capture in
                    pendingHomeMediaSelection = PendingHomeMediaSelection(intent: .capturedMedia(capture))
                    showHomeCameraCapture = false
                },
                onCancel: { showHomeCameraCapture = false }
            )
        }
        .photosPicker(
            isPresented: $showHomePhotoLibrary,
            selection: $selectedHomePhotoItems,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos])
        )
        .sheet(item: $pendingHomeMediaSelection) { selection in
            HomeMediaDestinationPicker(
                localDatabase: container.localDatabase,
                onConversationPicked: { conversationId in
                    router.deepLinkToConversation(
                        conversationId: conversationId,
                        pendingAttachment: selection.intent
                    )
                    pendingHomeMediaSelection = nil
                },
                onCancel: { pendingHomeMediaSelection = nil }
            )
        }
        .navigationDestination(isPresented: $showHiddenChats) {
            HiddenChatsView(
                localDatabase: container.localDatabase,
                messageRepository: container.messageRepository
            )
        }
        .navigationDestination(isPresented: $showArchivedChats) {
            ArchivedChatsView(
                localDatabase: container.localDatabase,
                messageRepository: container.messageRepository
            )
        }
        .refreshable {
            await viewModel.refresh(
                messageRepository: container.messageRepository,
                syncOrchestrator: container.syncOrchestrator
            )
        }
        .onAppear {
            // Sync chip with current Sanchr Mode state each time the screen is visible
            // (catches changes made in Settings while ChatsListView was in the nav stack).
            sanchrModeEnabled = container.privacySettings.sanchrModeEnabled
            // Reload cached conversations so unread counts reflect any DB changes made
            // while this view was off-screen (e.g. ChatDetailView marking messages as read).
            Task { await viewModel.loadCachedConversations(localDatabase: container.localDatabase) }
        }
        .task {
            await viewModel.loadCachedConversations(localDatabase: container.localDatabase)
            updatePresenceTrackingForVisibleConversations()
            await viewModel.loadConversations(messageRepository: container.messageRepository)
            updatePresenceTrackingForVisibleConversations()
            await openPendingConversationIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sanchrConversationStateDidChange)) { note in
            if let conversationId = note.userInfo?[RealtimeNotificationKey.conversationId] as? String,
               !conversationId.isEmpty
            {
                pendingConversationRefreshIDs.insert(conversationId)
            }
            scheduleConversationRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sanchrRealtimePresenceUpdated)) { note in
            guard let presence = note.userInfo?[RealtimeNotificationKey.presence]
                    as? Sanchr_Messaging_PresenceUpdate else { return }
            // Queue a refresh for every conversation that involves this peer so
            // the status dot updates without waiting for the next message event.
            // The DB is already current (updateUserPresence ran before this fires).
            for conversation in viewModel.conversations
                where conversation.participants.contains(where: { $0.id == presence.userID })
            {
                pendingConversationRefreshIDs.insert(conversation.id)
            }
            scheduleConversationRefresh()
        }
        .onChange(of: router.pendingConversationId) { _, _ in
            Task { await openPendingConversationIfNeeded() }
        }
        .onChange(of: viewModel.totalUnreadCount) { _, newCount in
            router.chatUnreadCount = newCount
        }
        .onDisappear {
            scheduledRefreshTask?.cancel()
            scheduledRefreshTask = nil
            untrackAllVisiblePresencePeers()
        }
        .alert("Couldn't load media", isPresented: Binding(
            get: { homeMediaLoadErrorMessage != nil },
            set: { if !$0 { homeMediaLoadErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(homeMediaLoadErrorMessage ?? "")
        }
        .overlay {
            if isPreparingHomeMedia {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text("Preparing media…")
                                .font(SanchrTypography.caption)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.74))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
            }
        }
        .onChange(of: selectedHomePhotoItems) { _, items in
            guard !items.isEmpty else { return }
            let selectedItems = items
            selectedHomePhotoItems = []
            Task {
                await prepareHomePhotoLibrarySelection(from: selectedItems)
            }
        }
    }

    private var mainContent: some View {
        Group {
            if viewModel.conversations.isEmpty && viewModel.isLoading {
                loadingState
            } else if viewModel.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .background(SanchrExportColors.background)
    }

    private var loadingState: some View {
        VStack(spacing: 0) {
            customHeader
            Spacer()
            ProgressView()
                .tint(.sanchrPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SanchrExportColors.background)
    }

    private var conversationList: some View {
        List {
            Section {
                customHeader
                    .listRowInsets(EdgeInsets())

                searchBar
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.top, 2)
                    .listRowInsets(EdgeInsets())

                chipBar
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .listRowInsets(EdgeInsets())

                if viewModel.isSyncing {
                    syncingIndicator
                        .listRowInsets(EdgeInsets())
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(SanchrExportColors.background)

            let pinned = viewModel.pinnedConversations
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { conversation in
                        conversationCell(conversation)
                    }
                } header: {
                    sectionHeaderLabel("PINNED", systemImage: "pin.fill")
                }
                .listRowSeparator(.hidden)
                .listRowBackground(SanchrExportColors.background)
            }

            let recent = viewModel.recentConversations
            if !recent.isEmpty {
                Section {
                    ForEach(recent) { conversation in
                        conversationCell(conversation)
                    }
                } header: {
                    sectionHeaderLabel("ALL CHATS")
                }
                .listRowSeparator(.hidden)
                .listRowBackground(SanchrExportColors.background)
            }

            if let error = viewModel.errorMessage {
                Section {
                    errorBanner(error)
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                        .listRowInsets(EdgeInsets())
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                Color.clear
                    .frame(height: 90)
                    .listRowInsets(EdgeInsets())
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(SanchrExportColors.background)
        .scrollDismissesKeyboard(.interactively)
    }

    private func conversationCell(_ conversation: Conversation) -> some View {
        Button {
            openConversation(conversation)
        } label: {
            ConversationRow(conversation: conversation)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                conversationToDelete = conversation
            } label: {
                Label("Delete", systemImage: "trash.fill")
            }
            .tint(.sanchrError)

            Button {
                Task {
                    await viewModel.archiveConversation(
                        conversation,
                        messageRepository: container.messageRepository
                    )
                }
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(Color(hex: 0x6B7280))

            Button {
                Task {
                    await viewModel.toggleMute(
                        conversation,
                        messageRepository: container.messageRepository,
                        notificationService: container.notificationServiceClient
                    )
                }
            } label: {
                Label(
                    conversation.isMuted ? "Unmute" : "Mute",
                    systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill"
                )
            }
            .tint(.sanchrWarning)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task {
                    await viewModel.togglePin(
                        conversation,
                        messageRepository: container.messageRepository
                    )
                }
            } label: {
                Label(
                    conversation.isPinned ? "Unpin" : "Pin",
                    systemImage: conversation.isPinned ? "pin.slash.fill" : "pin.fill"
                )
            }
            .tint(.sanchrPrimary)
        }
        .contextMenu {
            Button {
                Task {
                    await viewModel.togglePin(
                        conversation,
                        messageRepository: container.messageRepository
                    )
                }
            } label: {
                Label(
                    conversation.isPinned ? "Unpin" : "Pin",
                    systemImage: conversation.isPinned ? "pin.slash" : "pin"
                )
            }

            Button {
                Task {
                    await viewModel.toggleMute(
                        conversation,
                        messageRepository: container.messageRepository,
                        notificationService: container.notificationServiceClient
                    )
                }
            } label: {
                Label(
                    conversation.isMuted ? "Unmute" : "Mute",
                    systemImage: conversation.isMuted ? "bell" : "bell.slash"
                )
            }

            if conversation.unreadCount > 0 {
                Button {
                    Task { await viewModel.markAsRead(conversation, messageRepository: container.messageRepository) }
                } label: {
                    Label("Mark as Read", systemImage: "envelope.open")
                }
            }

            Button {
                Task {
                    await viewModel.archiveConversation(
                        conversation,
                        messageRepository: container.messageRepository
                    )
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }

            Divider()

            Button(role: .destructive) {
                conversationToDelete = conversation
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var customHeader: some View {
        SanchrBrandHeader(title: "Sanchr") {
            SanchrGlassCluster(spacing: 12) {
                HStack(spacing: 10) {
                    SanchrIconButton(systemName: "camera.fill") {
                        showHomeMediaOptions = true
                    }

                    Menu {
                        Button {
                            showNewConversation = true
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }

                        Button {
                            showHiddenChats = true
                        } label: {
                            Label("Hidden Chats", systemImage: "eye.slash")
                        }

                        Button {
                            showArchivedChats = true
                        } label: {
                            Label("Archived Chats", systemImage: "archivebox")
                        }

                        Button {
                            router.selectedTab = .settings
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Group {
                            if #available(iOS 26.0, *) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .frame(width: 40, height: 40)
                                    .sanchrGlass(
                                        role: .toolbarButton,
                                        interactive: true
                                    )
                            } else {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .frame(width: 40, height: 40)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        SanchrSearchField(placeholder: "Search chats...", text: $viewModel.searchText) {
            Button {
                viewModel.searchText = ""
            } label: {
                Image(systemName: viewModel.searchText.isEmpty ? "slider.horizontal.3" : "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SanchrSpacing.filterTabGap) {
                ForEach(ChatsListViewModel.ChatFilter.allCases) { filter in
                    SanchrFilterChip(
                        title: filter.rawValue,
                        isSelected: viewModel.selectedFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            viewModel.selectedFilter = filter
                        }
                    }
                }

                SanchrModeChip(isActive: sanchrModeEnabled) {
                    let desired = !sanchrModeEnabled
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sanchrModeEnabled = desired  // optimistic
                    }
                    Task {
                        do {
                            let updated = try await settingsDataSource.toggleSanchrMode(enabled: desired)
                            container.privacySettings.update(from: updated)
                            sanchrModeEnabled = updated.sanchrModeEnabled
                        } catch {
                            // Revert on failure
                            withAnimation(.easeInOut(duration: 0.18)) {
                                sanchrModeEnabled = !desired
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeaderLabel(_ title: String, systemImage: String? = nil) -> some View {
        SanchrSectionEyebrow(title: title, systemImage: systemImage)
            .listRowInsets(EdgeInsets())
            .textCase(nil)
    }

    private var syncingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.sanchrPrimary)
                .scaleEffect(0.82)
            Text("Syncing...")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.sanchrWarning)
            Text(error)
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SanchrExportColors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            customHeader

            Spacer()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(SanchrColors.primary.opacity(0.12))
                        .frame(width: 106, height: 106)

                    Image(systemName: "message.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(SanchrGradients.primaryDark)
                }

                Text("No conversations yet")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text("Start a new conversation to begin messaging securely.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    showNewConversation = true
                } label: {
                    SanchrGradientButtonLabel(title: "Start a Chat", systemName: "plus")
                }
                .buttonStyle(SanchrPrimaryCTA())
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SanchrExportColors.background)
    }

    private var fabButton: some View {
        Button {
            showNewConversation = true
        } label: {
            Group {
                if #available(iOS 26.0, *) {
                    Image(systemName: "plus")
                        .font(.system(size: SanchrSpacing.fabIconSize, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: SanchrSpacing.fabSize, height: SanchrSpacing.fabSize)
                        .sanchrGlass(
                            role: .floatingAction,
                            interactive: true,
                            prominence: .prominent,
                            tint: SanchrColors.primary
                        )
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: SanchrSpacing.fabIconSize, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: SanchrSpacing.fabSize, height: SanchrSpacing.fabSize)
                        .background(
                            LinearGradient(
                                colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                        .shadow(color: SanchrColors.primary.opacity(0.4), radius: 24, x: 0, y: 8)
                }
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private func openPendingConversationIfNeeded() async {
        guard let pendingConversationId = router.pendingConversationId else { return }

        if let conversation = viewModel.conversations.first(where: { $0.id == pendingConversationId }) {
            router.selectedTab = .chats
            router.chatsPath = NavigationPath()
            openConversation(conversation)
            router.clearPendingConversation()
            return
        }

        if let conversation = try? await container.localDatabase.fetchConversation(id: pendingConversationId) {
            router.selectedTab = .chats
            router.chatsPath = NavigationPath()
            openConversation(conversation)
            router.clearPendingConversation()
        }
    }

    private func openConversation(_ conversation: Conversation) {
        // Clear the unread badge immediately on navigation so the tab badge reflects
        // reality without waiting for the async ChatDetailView mark-as-read round-trip.
        // Direct router update is required because onChange(of: totalUnreadCount) may
        // not fire once ChatsListView is pushed off-screen by the navigation.
        if conversation.unreadCount > 0 {
            Task { await viewModel.markAsRead(conversation, messageRepository: container.messageRepository) }
            router.chatUnreadCount = max(0, router.chatUnreadCount - conversation.unreadCount)
        }
        router.chatsPath.append(conversation)
    }

    private func scheduleConversationRefresh(forceFullReload: Bool = false) {
        scheduledRefreshTask?.cancel()

        scheduledRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            let pendingIDs = pendingConversationRefreshIDs
            pendingConversationRefreshIDs.removeAll()

            if forceFullReload || pendingIDs.isEmpty {
                await viewModel.loadCachedConversations(localDatabase: container.localDatabase)
            } else {
                for conversationId in pendingIDs {
                    await viewModel.refreshConversation(
                        id: conversationId,
                        localDatabase: container.localDatabase
                    )
                }
            }

            updatePresenceTrackingForVisibleConversations()
            await openPendingConversationIfNeeded()
        }
    }

    private func updatePresenceTrackingForVisibleConversations() {
        let peerIds = Set(
            viewModel.conversations.compactMap { conversation -> String? in
                guard !conversation.isArchived,
                      conversation.type == .oneToOne,
                      let peer = conversation.participants.first(where: { !$0.isLocalUser }),
                      !peer.id.isEmpty
                else { return nil }
                return peer.id
            }
        )

        for peerId in trackedPresencePeerIds.subtracting(peerIds) {
            container.realtimeService.untrackPresencePeer(peerId)
        }

        for peerId in peerIds.subtracting(trackedPresencePeerIds) {
            container.realtimeService.trackPresencePeer(peerId)
        }

        trackedPresencePeerIds = peerIds
    }

    private func untrackAllVisiblePresencePeers() {
        for peerId in trackedPresencePeerIds {
            container.realtimeService.untrackPresencePeer(peerId)
        }
        trackedPresencePeerIds.removeAll()
    }

    @MainActor
    private func prepareHomePhotoLibrarySelection(from items: [PhotosPickerItem]) async {
        isPreparingHomeMedia = true
        defer { isPreparingHomeMedia = false }

        var pickedMedia: [PickedMedia] = []
        pickedMedia.reserveCapacity(items.count)

        for item in items {
            if let media = await loadPickedMedia(from: item) {
                pickedMedia.append(media)
            }
        }

        guard !pickedMedia.isEmpty else {
            homeMediaLoadErrorMessage = "Couldn't load the selected media."
            return
        }

        pendingHomeMediaSelection = PendingHomeMediaSelection(intent: .photoLibrary(pickedMedia))
    }

    private func loadPickedMedia(from item: PhotosPickerItem) async -> PickedMedia? {
        let supportedType = item.supportedContentTypes.first(where: {
            $0.conforms(to: .movie) || $0.conforms(to: .image)
        })

        if let supportedType, supportedType.conforms(to: .movie) {
            return await loadPickedVideo(from: item, contentType: supportedType)
        }

        return await loadPickedPhoto(from: item, contentType: supportedType)
    }

    private func loadPickedPhoto(from item: PhotosPickerItem, contentType: UTType?) async -> PickedMedia? {
        guard let sourceData = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: sourceData)
        else {
            SanchrLogger.chat.error("Home media picker failed to load selected image")
            return nil
        }

        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)

        let mimeType: String
        let payloadData: Data
        let filenameExtension: String
        if let contentType, contentType.conforms(to: .png) {
            mimeType = "image/png"
            payloadData = sourceData
            filenameExtension = "png"
        } else {
            mimeType = "image/jpeg"
            payloadData = image.jpegData(compressionQuality: 0.92) ?? sourceData
            filenameExtension = "jpg"
        }

        return PickedMedia(
            id: UUID(),
            kind: .photo,
            data: payloadData,
            fileURL: nil,
            originalFilename: "library-\(UUID().uuidString).\(filenameExtension)",
            mimeType: mimeType,
            width: pixelWidth,
            height: pixelHeight,
            durationSeconds: nil
        )
    }

    private func loadPickedVideo(from item: PhotosPickerItem, contentType: UTType) async -> PickedMedia? {
        guard let sourceData = try? await item.loadTransferable(type: Data.self) else {
            SanchrLogger.chat.error("Home media picker failed to load selected video")
            return nil
        }

        let fileExtension = contentType.preferredFilenameExtension ?? "mov"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")

        do {
            try sourceData.write(to: tempURL)
        } catch {
            SanchrLogger.chat.error("Home media picker failed to stage selected video: \(error.localizedDescription)")
            return nil
        }

        let asset = AVURLAsset(url: tempURL)
        let duration = try? await asset.load(.duration)
        let durationSeconds = duration.map(CMTimeGetSeconds).flatMap { seconds in
            seconds.isFinite ? seconds : nil
        }

        let posterImage = makeVideoPosterImage(for: asset)
        let pixelWidth = posterImage.map { Int($0.size.width * $0.scale) } ?? 0
        let pixelHeight = posterImage.map { Int($0.size.height * $0.scale) } ?? 0

        return PickedMedia(
            id: UUID(),
            kind: .video,
            data: Data(),
            fileURL: tempURL,
            originalFilename: "library-\(UUID().uuidString).\(fileExtension)",
            mimeType: contentType.preferredMIMEType ?? "video/mp4",
            width: pixelWidth,
            height: pixelHeight,
            durationSeconds: durationSeconds
        )
    }

    private func makeVideoPosterImage(for asset: AVURLAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private struct HomeMediaDestinationPicker: View {
    let localDatabase: LocalDatabaseProtocol
    let onConversationPicked: (String) -> Void
    let onCancel: () -> Void

    @State private var summaries: [ShareChatSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredSummaries: [ShareChatSummary] {
        guard !searchText.isEmpty else { return summaries }
        return summaries.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Couldn't load chats")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(loadError)
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredSummaries.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No chats available" : "No matches",
                        systemImage: "message",
                        description: Text(
                            searchText.isEmpty
                                ? "Start a chat first, then capture media to send."
                                : "Try a different name."
                        )
                    )
                } else {
                    List(filteredSummaries, id: \.id) { summary in
                        Button {
                            onConversationPicked(summary.id)
                        } label: {
                            HomeMediaDestinationRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(SanchrExportColors.background)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(SanchrExportColors.background)
                    .searchable(text: $searchText, prompt: "Search chats")
                }
            }
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .background(SanchrExportColors.background.ignoresSafeArea())
        }
        .presentationDetents([.large])
        .task { await loadSummaries() }
    }

    private func loadSummaries() async {
        do {
            summaries = try await localDatabase.fetchShareChatSummaries()
                .sorted { $0.lastActivityMs > $1.lastActivityMs }
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

private struct HomeMediaDestinationRow: View {
    let summary: ShareChatSummary

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials(for: summary.title))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .lineLimit(1)
                if let preview = summary.lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SanchrExportColors.textTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return initials.isEmpty ? "?" : initials
    }
}

private struct HiddenChatsView: View {
    let localDatabase: LocalDatabaseProtocol
    let messageRepository: MessageRepositoryProtocol

    @Environment(AppRouter.self) private var router
    @State private var summaries: [ShareChatSummary] = []
    @State private var isLoading = true
    @State private var isRestoringConversationIds: Set<String> = []
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredSummaries: [ShareChatSummary] {
        guard !searchText.isEmpty else { return summaries }
        return summaries.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(.sanchrPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load hidden chats")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(loadError)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSummaries.isEmpty {
                ContentUnavailableView(
                    summaries.isEmpty ? "No hidden chats" : "No matches",
                    systemImage: "eye.slash",
                    description: Text(
                        summaries.isEmpty
                            ? "Chats removed from this device will appear here."
                            : "Try a different name."
                    )
                )
            } else {
                List {
                    ForEach(filteredSummaries, id: \.id) { summary in
                        HiddenChatRow(
                            summary: summary,
                            isRestoring: isRestoringConversationIds.contains(summary.id),
                            onOpen: { router.deepLinkToConversation(conversationId: summary.id) },
                            onRestore: { restore(summary.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(SanchrExportColors.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(SanchrExportColors.background)
                .searchable(text: $searchText, prompt: "Search hidden chats")
            }
        }
        .navigationTitle("Hidden Chats")
        .navigationBarTitleDisplayMode(.inline)
        .background(SanchrExportColors.background.ignoresSafeArea())
        .task { await loadSummaries() }
    }

    @MainActor
    private func loadSummaries() async {
        do {
            summaries = try await localDatabase.fetchHiddenChatSummaries()
                .sorted { $0.lastActivityMs > $1.lastActivityMs }
            isLoading = false
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func restore(_ conversationId: String) {
        guard !isRestoringConversationIds.contains(conversationId) else { return }
        isRestoringConversationIds.insert(conversationId)

        Task {
            do {
                try await messageRepository.restoreConversationLocally(conversationId: conversationId)
                await MainActor.run {
                    summaries.removeAll { $0.id == conversationId }
                    isRestoringConversationIds.remove(conversationId)
                    router.deepLinkToConversation(conversationId: conversationId)
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isRestoringConversationIds.remove(conversationId)
                }
            }
        }
    }
}

private struct ArchivedChatsView: View {
    let localDatabase: LocalDatabaseProtocol
    let messageRepository: MessageRepositoryProtocol

    @Environment(AppRouter.self) private var router
    @State private var summaries: [ShareChatSummary] = []
    @State private var isLoading = true
    @State private var isUpdatingConversationIds: Set<String> = []
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredSummaries: [ShareChatSummary] {
        guard !searchText.isEmpty else { return summaries }
        return summaries.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(.sanchrPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load archived chats")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(loadError)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSummaries.isEmpty {
                ContentUnavailableView(
                    summaries.isEmpty ? "No archived chats" : "No matches",
                    systemImage: "archivebox",
                    description: Text(
                        summaries.isEmpty
                            ? "Archived chats will appear here."
                            : "Try a different name."
                    )
                )
            } else {
                List {
                    ForEach(filteredSummaries, id: \.id) { summary in
                        ArchivedChatRow(
                            summary: summary,
                            isUpdating: isUpdatingConversationIds.contains(summary.id),
                            onOpen: { router.deepLinkToConversation(conversationId: summary.id) },
                            onUnarchive: { unarchive(summary.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(SanchrExportColors.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(SanchrExportColors.background)
                .searchable(text: $searchText, prompt: "Search archived chats")
            }
        }
        .navigationTitle("Archived Chats")
        .navigationBarTitleDisplayMode(.inline)
        .background(SanchrExportColors.background.ignoresSafeArea())
        .task { await loadSummaries() }
    }

    @MainActor
    private func loadSummaries() async {
        do {
            summaries = try await localDatabase.fetchArchivedChatSummaries()
                .sorted { $0.lastActivityMs > $1.lastActivityMs }
            isLoading = false
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    private func unarchive(_ conversationId: String) {
        guard !isUpdatingConversationIds.contains(conversationId) else { return }
        isUpdatingConversationIds.insert(conversationId)

        Task {
            do {
                try await messageRepository.setConversationArchived(
                    conversationId: conversationId,
                    isArchived: false
                )
                await MainActor.run {
                    summaries.removeAll { $0.id == conversationId }
                    isUpdatingConversationIds.remove(conversationId)
                    router.deepLinkToConversation(conversationId: conversationId)
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isUpdatingConversationIds.remove(conversationId)
                }
            }
        }
    }
}

private struct HiddenChatRow: View {
    let summary: ShareChatSummary
    let isRestoring: Bool
    let onOpen: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials(for: summary.title))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .lineLimit(1)

                if let preview = summary.lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Removed from this device")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                onRestore()
            } label: {
                if isRestoring {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(width: 24, height: 24)
                } else {
                    Text("Restore")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SanchrColors.primary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return initials.isEmpty ? "?" : initials
    }
}

private struct ArchivedChatRow: View {
    let summary: ShareChatSummary
    let isUpdating: Bool
    let onOpen: () -> Void
    let onUnarchive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials(for: summary.title))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .lineLimit(1)

                if let preview = summary.lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Archived")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                onUnarchive()
            } label: {
                if isUpdating {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(width: 24, height: 24)
                } else {
                    Text("Unarchive")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SanchrColors.primary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return initials.isEmpty ? "?" : initials
    }
}

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
                        if conversation.type == .group,
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
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
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
        switch event {
        case .identityKeyChanged:
            return "Security code changed"
        case .disappearingTimerChanged:
            return "Disappearing timer changed"
        case .groupCreated:
            return "Group created"
        case .memberAdded:
            return "Member added"
        case .memberRemoved:
            return "Member removed"
        case .screenshotDetected:
            return "Screenshot detected"
        case .viewOnceConsumed:
            return "Viewed"
        case .autoVaulted:
            return "Auto-vaulted media"
        }
    }
}

private struct ChatRowButtonStyle: ButtonStyle {
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

private struct PulseModifier: ViewModifier {
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
