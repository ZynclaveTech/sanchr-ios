import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SanchrShared

@MainActor
struct VaultView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = VaultViewModel()
    @State private var showAddSheet = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    private var vaultDataSource: VaultDataSource {
        container.vaultDataSource
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    statsRow
                    filterTabs
                    content
                }
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                .padding(.top, 24)
                .padding(.bottom, 110)
            }
            .refreshable {
                await viewModel.loadItems(
                    vaultDataSource: vaultDataSource,
                    accessKeyStore: container.accessKeyStore,
                    mediaEncryption: container.mediaEncryption
                )
            }
            .background(SanchrExportColors.background.ignoresSafeArea())

            addButton
        }
        .navigationTitle(viewModel.isSelectMode ? selectModeTitle : "Vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isSelectMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.exitSelectMode()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Select all") {
                            viewModel.selectAllVisible()
                        }
                        if !viewModel.selectedItemIds.isEmpty {
                            Button("Delete \(viewModel.selectedItemIds.count) item\(viewModel.selectedItemIds.count == 1 ? "" : "s")", role: .destructive) {
                                Task {
                                    await viewModel.deleteSelectedItems(
                                        vaultDataSource: vaultDataSource,
                                        localDatabase: container.localDatabase
                                    )
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            viewModel.enterSelectMode()
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }

                        Menu {
                            ForEach(VaultViewModel.SortOrder.allCases) { order in
                                Button {
                                    viewModel.changeSort(order)
                                } label: {
                                    HStack {
                                        Text(order.displayName)
                                        if viewModel.activeSort == order {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addToVaultSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .spreadsheet, .presentation, .data, .archive, .item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                // Load every selected file into memory eagerly. We hold
                // each security-scoped resource only for the duration of
                // the `Data(contentsOf:)` read; the upload dispatcher
                // then operates on the in-memory bytes.
                var specs: [VaultViewModel.UploadSpec] = []
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        specs.append(
                            VaultViewModel.UploadSpec(
                                fileName: url.lastPathComponent,
                                mediaType: "file",
                                data: data
                            )
                        )
                    }
                }
                await viewModel.enqueueUploads(
                    specs,
                    vaultDataSource: vaultDataSource,
                    mediaManager: container.mediaManager
                )
            }
        }
        // Files export sheet. Bound to shareState == .exportingToFiles
        // via a computed binding. On dismiss, cleanup runs regardless
        // of success/cancel.
        .sheet(
            isPresented: Binding(
                get: {
                    if case .exportingToFiles = viewModel.shareState { return true }
                    return false
                },
                set: { presented in
                    if !presented, case .exportingToFiles(let item, let tempURL) = viewModel.shareState {
                        viewModel.didFinishFilesExport(
                            for: item,
                            tempURL: tempURL,
                            success: false
                        )
                    }
                }
            )
        ) {
            if case .exportingToFiles(let item, let tempURL) = viewModel.shareState {
                VaultFilesExportView(tempURL: tempURL) { success in
                    viewModel.didFinishFilesExport(
                        for: item,
                        tempURL: tempURL,
                        success: success
                    )
                }
            }
        }
        // Share destination chooser (Flow B entry). Bound to
        // shareState == .choosingDestination. User picks "Share in
        // chat" → chooseShareInChat (Task 9 lands the picker) or
        // "Share outside Sanchr" → chooseShareOutside which downloads
        // via the coordinator and transitions to .externalSharing.
        .sheet(
            isPresented: Binding(
                get: {
                    if case .choosingDestination = viewModel.shareState { return true }
                    return false
                },
                set: { presented in
                    if !presented, case .choosingDestination = viewModel.shareState {
                        viewModel.cancelShare()
                    }
                }
            )
        ) {
            if case .choosingDestination(let item) = viewModel.shareState {
                VaultShareDestinationSheet(
                    item: item,
                    onShareInChat: {
                        viewModel.chooseShareInChat(for: item)
                    },
                    onShareOutside: {
                        Task {
                            await viewModel.chooseShareOutside(
                                for: item,
                                sharingCoordinator: container.vaultSharingCoordinator
                            )
                        }
                    },
                    onCancel: {
                        viewModel.cancelShare()
                    }
                )
            }
        }
        // External share sheet (Flow B2 terminal). Bound to
        // shareState == .externalSharing. Presents the iOS stock
        // UIActivityViewController wrapped by VaultActivityView. On
        // completion (success or cancel) cleans up the temp file and
        // clears share state.
        .sheet(
            isPresented: Binding(
                get: {
                    if case .externalSharing = viewModel.shareState { return true }
                    return false
                },
                set: { presented in
                    if !presented, case .externalSharing(let item, let tempURL) = viewModel.shareState {
                        viewModel.didFinishExternalShare(
                            for: item,
                            tempURL: tempURL,
                            completed: false,
                            sharingCoordinator: container.vaultSharingCoordinator
                        )
                    }
                }
            )
        ) {
            if case .externalSharing(let item, let tempURL) = viewModel.shareState {
                VaultActivityView(items: [tempURL]) { completed in
                    viewModel.didFinishExternalShare(
                        for: item,
                        tempURL: tempURL,
                        completed: completed,
                        sharingCoordinator: container.vaultSharingCoordinator
                    )
                }
            }
        }
        // Conversation picker (Flow B1). Bound to shareState ==
        // .pickingConversation. Lists conversations from the local DB
        // sorted by last-activity timestamp; picking one routes
        // through confirmConversation which applies the 25MB threshold.
        .sheet(
            isPresented: Binding(
                get: {
                    if case .pickingConversation = viewModel.shareState { return true }
                    return false
                },
                set: { presented in
                    if !presented, case .pickingConversation = viewModel.shareState {
                        viewModel.cancelShare()
                    }
                }
            )
        ) {
            if case .pickingConversation(let item) = viewModel.shareState {
                VaultChatDestinationPicker(
                    item: item,
                    localDatabase: container.localDatabase,
                    onConversationPicked: { convId, convName in
                        Task {
                            await viewModel.confirmConversation(
                                conversationId: convId,
                                conversationName: convName,
                                for: item,
                                sharingCoordinator: container.vaultSharingCoordinator
                            )
                        }
                    },
                    onCancel: {
                        viewModel.cancelShare()
                    }
                )
            }
        }
        // 25MB re-upload confirmation alert (Flow B1). Bound to
        // shareState == .confirmingLargeReupload. Destructive Send
        // proceeds with the share; Cancel returns to the picker.
        .alert(
            "Large file",
            isPresented: Binding(
                get: {
                    if case .confirmingLargeReupload = viewModel.shareState { return true }
                    return false
                },
                set: { presented in
                    if !presented {
                        viewModel.cancelLargeReupload()
                    }
                }
            )
        ) {
            Button("Send", role: .destructive) {
                Task {
                    await viewModel.confirmLargeReupload(
                        sharingCoordinator: container.vaultSharingCoordinator
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelLargeReupload()
            }
        } message: {
            if case .confirmingLargeReupload(_, _, let cname, let sz) = viewModel.shareState {
                Text(
                    String(
                        format: "This will re-upload %.1f MB to %@. Continue?",
                        Double(sz) / (1024 * 1024),
                        cname
                    )
                )
            } else {
                Text("")
            }
        }
        // Transient completion toast ("Saved to Photos" / "Saved").
        // Auto-clears after ~2.5s via takeShareCompletionToast. The
        // id: modifier forces SwiftUI to rebuild the view on each new
        // toast so the auto-clear task reruns.
        .overlay(alignment: .top) {
            if let toast = viewModel.shareCompletionToast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        _ = viewModel.takeShareCompletionToast()
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.shareCompletionToast)
        .task {
            // One-shot initial fetch. Filter changes are purely client-side
            // via `filteredItems` — no reload needed.
            await viewModel.loadItems(
                vaultDataSource: vaultDataSource,
                accessKeyStore: container.accessKeyStore,
                mediaEncryption: container.mediaEncryption
            )
        }
    }

    private var selectModeTitle: String {
        if viewModel.selectedItemIds.isEmpty {
            return "Select items"
        }
        let count = viewModel.selectedItemIds.count
        return "\(count) selected"
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            VaultStatCard(
                icon: "photo.fill",
                tint: SanchrColors.primary,
                title: "\(viewModel.totalPhotos)",
                subtitle: "Photos"
            )
            VaultStatCard(
                icon: "video.fill",
                tint: SanchrColors.accent,
                title: "\(viewModel.totalVideos)",
                subtitle: "Videos"
            )
            VaultStatCard(
                icon: "doc.fill",
                tint: Color(hex: 0x9333EA),
                title: "\(viewModel.totalFiles)",
                subtitle: "Files"
            )
        }
    }

    private var filterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(VaultViewModel.Filter.allCases) { filter in
                    SanchrFilterChip(
                        title: filter.displayName,
                        isSelected: viewModel.activeFilter == filter
                    ) {
                        viewModel.changeFilter(filter)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 16) {
            // Upload progress cards are hoisted above the main content
            // branching so the user sees feedback on the very first upload
            // (when the items list is still empty). One card per active or
            // failed upload.
            if !viewModel.uploads.isEmpty {
                VStack(spacing: 12) {
                    ForEach(viewModel.uploads) { task in
                        uploadProgressCard(for: task)
                    }
                }
            }

            mainContentBranch
        }
    }

    @ViewBuilder
    private var mainContentBranch: some View {
        if viewModel.isLoading {
            ProgressView()
                .tint(.sanchrPrimary)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else if viewModel.filteredItems.isEmpty {
            // While uploading the first item, suppress the empty state so
            // the upload progress card above is the only thing visible.
            if !viewModel.isUploading {
                emptyState
            }
        } else {
            let visible = viewModel.filteredItems
            LazyVStack(spacing: 16) {
                ForEach(visible) { item in
                    selectableCard(for: item)
                        .onAppear {
                            if item.id == visible.last?.id {
                                Task {
                                    await viewModel.loadMore(
                                        vaultDataSource: vaultDataSource,
                                        accessKeyStore: container.accessKeyStore,
                                        mediaEncryption: container.mediaEncryption
                                    )
                                }
                            }
                        }
                }

                if viewModel.isLoadingMore {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func selectableCard(for item: VaultItem) -> some View {
        let isSelected = viewModel.selectedItemIds.contains(item.id)

        HStack(spacing: 12) {
            if viewModel.isSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        isSelected ? SanchrColors.primary : SanchrExportColors.textTertiary
                    )
                    .transition(.opacity.combined(with: .scale))
            }

            VaultItemCard(
                item: item,
                onDelete: {
                    Task {
                        await viewModel.deleteItem(
                            item,
                            vaultDataSource: vaultDataSource,
                            localDatabase: container.localDatabase
                        )
                    }
                },
                onShare: {
                    viewModel.requestShare(item)
                },
                onSave: {
                    Task {
                        await viewModel.requestSave(
                            item,
                            vaultRepository: container.vaultRepository,
                            photosSaver: container.photosSaver
                        )
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if viewModel.isSelectMode {
                viewModel.toggleSelection(for: item.id)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isSelectMode)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(emptyStateGradient)
                .frame(height: 220)
                .overlay {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.doc.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(SanchrGradients.primaryDark)
                        Text("Your vault is empty")
                            .font(SanchrTypography.cardTitle)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text("Store photos, documents, and notes with end-to-end encryption.")
                            .font(SanchrTypography.body)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 28)
                }
        }
    }

    /// Dark-mode-aware gradient for the empty-state card. Light mode keeps the
    /// original pale indigo → cyan wash; dark mode uses a subtle elevated
    /// surface pair so the card reads as a panel against the dark background
    /// instead of a blinding light tile.
    private var emptyStateGradient: LinearGradient {
        let colors: [Color] =
            colorScheme == .dark
                ? [Color(hex: 0x1E1B3A), Color(hex: 0x0F2033)]
                : [Color(hex: 0xEEF2FF), Color(hex: 0xECFEFF)]
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private func uploadProgressCard(for task: VaultViewModel.UploadTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: mediaTypeIcon(for: task.mediaType))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SanchrColors.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.fileName)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(uploadSubtitle(for: task.state))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
                Spacer()
                if case .failed = task.state {
                    Button {
                        viewModel.dismissFailedUpload(id: task.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(SanchrExportColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            switch task.state {
            case .pending:
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.sanchrPrimary)
            case .uploading(let progress):
                ProgressView(value: progress)
                    .tint(.sanchrPrimary)
            case .failed:
                // No progress bar on failed rows — the xmark dismiss
                // button is the affordance.
                EmptyView()
            }
        }
        .padding(18)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func uploadSubtitle(for state: VaultViewModel.UploadTask.State) -> String {
        switch state {
        case .pending:
            return "Queued"
        case .uploading(let progress):
            return "\(Int(progress * 100))% uploaded"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private func mediaTypeIcon(for mediaType: String) -> String {
        switch mediaType {
        case "photo": return "photo.fill"
        case "video": return "video.fill"
        case "audio": return "waveform"
        case "note": return "note.text"
        default: return "doc.fill"
        }
    }

    private var addButton: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                Text("Add to Vault")
                    .font(SanchrTypography.bodyBold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(
                LinearGradient(
                    colors: [SanchrColors.primary, SanchrColors.primaryDark],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: SanchrColors.primary.opacity(0.28), radius: 24, x: 0, y: 14)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private var addToVaultSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 0,  // 0 = unlimited
                    matching: .any(of: [.images, .videos])
                ) {
                    VaultSheetRow(
                        icon: "photo.on.rectangle.fill",
                        tint: SanchrColors.primary,
                        title: "Photos or Videos",
                        subtitle: "Select one or more from your library"
                    )
                }

                Button {
                    showAddSheet = false
                    showFileImporter = true
                } label: {
                    VaultSheetRow(
                        icon: "doc.fill",
                        tint: SanchrColors.accent,
                        title: "Document",
                        subtitle: "PDF, DOC, and more"
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(SanchrExportMetrics.screenHorizontal)
            .padding(.top, 20)
            .navigationTitle("Add to Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .onChange(of: selectedPhotoItems) { _, newValue in
            guard !newValue.isEmpty else { return }

            // Snapshot and clear the selection immediately so the picker
            // doesn't re-fire on the same batch if the user bounces back.
            let batch = newValue
            selectedPhotoItems = []

            Task {
                var specs: [VaultViewModel.UploadSpec] = []
                for item in batch {
                    let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
                    let ext = isVideo ? "mp4" : "jpg"
                    let mediaType = isVideo ? "video" : "photo"

                    if let data = try? await item.loadTransferable(type: Data.self) {
                        specs.append(
                            VaultViewModel.UploadSpec(
                                fileName: "vault_\(UUID().uuidString.prefix(8)).\(ext)",
                                mediaType: mediaType,
                                data: data
                            )
                        )
                    }
                }
                showAddSheet = false
                await viewModel.enqueueUploads(
                    specs,
                    vaultDataSource: vaultDataSource,
                    mediaManager: container.mediaManager
                )
            }
        }
    }
}

private struct VaultStatCard: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sanchrPrimary)
                }

            Text(title)
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text(subtitle)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct VaultSheetRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.sanchrPrimary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct VaultItemCard: View {
    let item: VaultItem
    var onDelete: () -> Void = {}
    var onShare: () -> Void = {}
    var onSave: () -> Void = {}

    @State private var thumbnail: UIImage?

    /// Human-friendly sliding-TTL expiry label. Uses
    /// `AccessKeyStore.defaultTTL` (currently 30 days) as the ceiling, then
    /// rounds to the coarsest unit that still reads cleanly (e.g. "29d",
    /// "5h", "45m", "Expiring soon"). "Sliding" is an honest word because
    /// the TTL refreshes on every access — the countdown the user sees is
    /// "time since last open" + TTL, not a hard deadline.
    private var expiryText: String {
        let ttl = AccessKeyStore.defaultTTL
        let elapsed = Date().timeIntervalSince(item.createdAt)
        let remaining = ttl - elapsed

        guard remaining > 0 else { return "Expired" }

        let days = Int(remaining / 86_400)
        let hours = Int(remaining / 3_600)
        let minutes = Int(remaining / 60)

        if days >= 1 {
            return "\(days)d left"
        } else if hours >= 1 {
            return "\(hours)h left"
        } else if minutes >= 1 {
            return "\(minutes)m left"
        } else {
            return "Expiring soon"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(thumbnailGradient)
                    .frame(height: 192)
                    .overlay {
                        ZStack {
                            if let thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            } else {
                                Image(systemName: item.type.systemImage)
                                    .font(.system(size: 52))
                                    .foregroundColor(iconTint.opacity(0.35))
                            }

                            if item.type == .video {
                                Circle()
                                    .fill(Color.white.opacity(0.92))
                                    .frame(width: 64, height: 64)
                                    .overlay {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(SanchrColors.primary)
                                            .offset(x: 2)
                                    }
                            }
                        }
                    }
                    .clipped()

                Text(typeLabel)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(14)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(SanchrExportColors.surfaceMuted)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .lineLimit(1)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }

                    Spacer()

                    Menu {
                        // Save and Share live on the footer action row.
                        // The three-dot menu keeps only destructive
                        // actions so the card's overflow doesn't
                        // duplicate the primary affordances.
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(SanchrExportColors.surfaceMuted)
                            .clipShape(Circle())
                    }
                }

                HStack {
                    HStack(spacing: 18) {
                        VaultActionButton(
                            icon: "square.and.arrow.down",
                            title: "Save",
                            tint: SanchrColors.primary,
                            action: onSave
                        )
                        VaultActionButton(
                            icon: "square.and.arrow.up",
                            title: "Share",
                            tint: SanchrExportColors.textSecondary,
                            action: onShare
                        )
                    }

                    Spacer()

                    Text(expiryText)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color(hex: 0xEA580C))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color(hex: 0xFFF7ED))
                        .clipShape(Capsule())
                }
            }
            .padding(16)
        }
        .background(
            LinearGradient(
                colors: [SanchrExportColors.surface, SanchrExportColors.surfaceMuted],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .task {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: item)
        }
    }

    private var typeLabel: String {
        switch item.type {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .document:
            return "File"
        case .audio:
            return "Audio"
        case .note:
            return "Note"
        }
    }

    private var thumbnailGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var gradientColors: [Color] {
        switch item.type {
        case .photo:
            return [SanchrColors.primary.opacity(0.18), SanchrColors.accent.opacity(0.18)]
        case .video:
            return [SanchrColors.accent.opacity(0.2), SanchrColors.primary.opacity(0.18)]
        case .document:
            return [Color(hex: 0xF3E8FF), Color(hex: 0xFCE7F3)]
        case .audio:
            return [Color(hex: 0xDBEAFE), Color(hex: 0xE0F2FE)]
        case .note:
            return [Color(hex: 0xFEF3C7), Color(hex: 0xFDE68A)]
        }
    }

    private var iconTint: Color {
        switch item.type {
        case .photo:
            return SanchrColors.primary
        case .video:
            return SanchrColors.accent
        case .document:
            return Color(hex: 0x7C3AED)
        case .audio:
            return Color(hex: 0x2563EB)
        case .note:
            return Color(hex: 0xD97706)
        }
    }
}

/// `UIViewControllerRepresentable` wrapper around
/// `UIDocumentPickerViewController(forExporting:)` used for the Files
/// export path of the Save flow. Invokes `onDismiss(success)` when the
/// picker closes — success==true means the user picked a destination,
/// false means they cancelled. Either way the view model cleans up the
/// temp directory on receipt of the callback.
private struct VaultFilesExportView: UIViewControllerRepresentable {
    let tempURL: URL
    let onDismiss: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDismiss: (Bool) -> Void
        init(onDismiss: @escaping (Bool) -> Void) { self.onDismiss = onDismiss }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss(false)
        }
    }
}

private struct VaultActionButton: View {
    let icon: String
    let title: String
    let tint: Color
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.sanchrPrimary)
                Text(title)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
