import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Encrypted vault screen for secure file storage.
/// Matches Figma: vault-screen.
@MainActor
struct VaultView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = VaultViewModel()
    @State private var showAddSheet = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showFileImporter = false

    private var vaultDataSource: VaultDataSource {
        VaultDataSource(
            grpcClient: container.grpcClient,
            mediaEncryption: container.mediaEncryption
        )
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: SanchrSpacing.md) {
                        // Secure Storage card
                        secureStorageCard

                        // Stats row
                        statsRow

                        // Filter tabs
                        filterTabs

                        // Content
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.sanchrPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, SanchrSpacing.mega)
                        } else if viewModel.items.isEmpty {
                            emptyState
                        } else {
                            itemsGrid
                        }

                        // Upload progress
                        if viewModel.isUploading {
                            uploadProgressView
                        }

                        // Bottom notice
                        if !viewModel.items.isEmpty {
                            bottomNotice
                        }

                        // Pagination loader
                        if viewModel.isLoadingMore {
                            ProgressView()
                                .tint(.sanchrPrimary)
                                .padding()
                        }
                    }
                    .padding(.horizontal, SanchrSpacing.md)
                    .padding(.bottom, SanchrSpacing.mega)
                }
                .refreshable {
                    await viewModel.loadItems(vaultDataSource: vaultDataSource)
                }

                // FAB: "+ Add to Vault"
                addButton
            }
            .navigationTitle("Vault")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            // Select multiple items
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Button {
                            // Sort options
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.sanchrPrimary)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                addToVaultSheet
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .plainText, .spreadsheet, .presentation,
                                      .data, .archive, .item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        await viewModel.uploadItem(
                            data: data,
                            fileName: url.lastPathComponent,
                            mediaType: "file",
                            senderID: container.sessionService.currentUserId ?? "",
                            vaultDataSource: vaultDataSource,
                            mediaManager: container.mediaManager
                        )
                    }
                }
            }
            .task(id: viewModel.activeFilter) {
                await viewModel.loadItems(vaultDataSource: vaultDataSource)
            }
        }
    }

    // MARK: - Secure Storage Card

    private var secureStorageCard: some View {
        HStack(spacing: SanchrSpacing.md) {
            Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(SanchrGradients.primary)
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))

            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                Text("Secure Storage")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                Text("Self-destructing media")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }

            Spacer()

            // Encryption badge
            HStack(spacing: SanchrSpacing.xxxs) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("E2EE")
                    .font(SanchrTypography.micro)
            }
            .foregroundColor(SanchrColors.encryptionBadgeText)
            .padding(.horizontal, SanchrSpacing.xs)
            .padding(.vertical, SanchrSpacing.xxxs)
            .background(SanchrColors.encryptionBadge)
            .clipShape(Capsule())
        }
        .padding(SanchrSpacing.md)
        .background(Color.sanchrSurfaceElevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
        .sanchrCardShadow()
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: SanchrSpacing.md) {
            statItem(icon: "photo.fill", count: viewModel.totalPhotos, label: "Photos")
            statItem(icon: "video.fill", count: viewModel.totalVideos, label: "Videos")
            statItem(icon: "doc.fill", count: viewModel.totalFiles, label: "Files")
        }
    }

    private func statItem(icon: String, count: Int32, label: String) -> some View {
        VStack(spacing: SanchrSpacing.xxs) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.sanchrPrimary)
            Text("\(count)")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
            Text(label)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SanchrSpacing.sm)
        .background(Color.sanchrSurfaceElevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
    }

    // MARK: - Filter Tabs

    private var filterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SanchrSpacing.xs) {
                ForEach(VaultViewModel.Filter.allCases) { filter in
                    Button {
                        Task {
                            await viewModel.changeFilter(filter, vaultDataSource: vaultDataSource)
                        }
                    } label: {
                        HStack(spacing: SanchrSpacing.xxs) {
                            Image(systemName: filter.icon)
                                .font(.caption)
                            Text(filter.displayName)
                                .font(SanchrTypography.caption)
                        }
                        .padding(.horizontal, SanchrSpacing.md)
                        .padding(.vertical, SanchrSpacing.xs)
                        .background(
                            viewModel.activeFilter == filter
                                ? AnyShapeStyle(SanchrGradients.primary)
                                : AnyShapeStyle(Color.sanchrSurfaceElevated(colorScheme))
                        )
                        .foregroundColor(
                            viewModel.activeFilter == filter
                                ? .white
                                : Color.sanchrTextSecondary(colorScheme)
                        )
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Items Grid

    private var itemsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: SanchrSpacing.sm),
                GridItem(.flexible(), spacing: SanchrSpacing.sm),
            ],
            spacing: SanchrSpacing.sm
        ) {
            ForEach(viewModel.items) { item in
                VaultItemCard(
                    item: item,
                    colorScheme: colorScheme,
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
                        // Share action - would present recipient picker
                    }
                )
                .onAppear {
                    // Pagination: load more when last item appears
                    if item.id == viewModel.items.last?.id {
                        Task {
                            await viewModel.loadMore(vaultDataSource: vaultDataSource)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: SanchrSpacing.md) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 64))
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            Text("Your vault is empty")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
            Text("Store photos, documents, and notes with end-to-end encryption")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.top, SanchrSpacing.mega)
    }

    // MARK: - Upload Progress

    private var uploadProgressView: some View {
        HStack(spacing: SanchrSpacing.sm) {
            ProgressView(value: viewModel.uploadProgress)
                .tint(.sanchrPrimary)
            Text("\(Int(viewModel.uploadProgress * 100))%")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
        }
        .padding(SanchrSpacing.md)
        .background(Color.sanchrSurfaceElevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
    }

    // MARK: - Bottom Notice

    private var bottomNotice: some View {
        HStack(spacing: SanchrSpacing.xs) {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundColor(SanchrColors.encryptionBadgeText)
            Text("All vault media is encrypted and will self-destruct after the set timer expires")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
        }
        .padding(SanchrSpacing.sm)
    }

    // MARK: - FAB

    private var addButton: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: SanchrSpacing.xs) {
                Image(systemName: "plus")
                    .font(.body.bold())
                Text("Add to Vault")
                    .font(SanchrTypography.button)
            }
            .foregroundColor(.white)
            .padding(.horizontal, SanchrSpacing.lg)
            .padding(.vertical, SanchrSpacing.sm)
            .background(SanchrGradients.primary)
            .clipShape(Capsule())
            .sanchrElevatedShadow()
            .sanchrPrimaryGlow()
        }
        .padding(SanchrSpacing.md)
    }

    // MARK: - Add Sheet

    private var addToVaultSheet: some View {
        NavigationStack {
            VStack(spacing: SanchrSpacing.lg) {
                let currentScheme = colorScheme
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .any(of: [.images, .videos])
                ) {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundColor(.sanchrPrimary)
                        VStack(alignment: .leading) {
                            Text("Photo or Video")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(Color.sanchrTextPrimary(currentScheme))
                            Text("Select from your library")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(currentScheme))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(Color.sanchrTextTertiary(currentScheme))
                    }
                    .padding(SanchrSpacing.md)
                    .background(Color.sanchrSurfaceElevated(currentScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
                }

                Button {
                    showAddSheet = false
                    showFileImporter = true
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "doc.fill")
                            .font(.title2)
                            .foregroundColor(.sanchrPrimary)
                        VStack(alignment: .leading) {
                            Text("Document")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text("PDF, DOC, and more")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                    }
                    .padding(SanchrSpacing.md)
                    .background(Color.sanchrSurfaceElevated(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
                }

                Spacer()
            }
            .padding(SanchrSpacing.md)
            .navigationTitle("Add to Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                // Detect media type from the picker item's supported types
                let isVideo = newValue.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
                let ext = isVideo ? "mp4" : "jpg"
                let mediaType = isVideo ? "video" : "photo"

                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    showAddSheet = false
                    await viewModel.uploadItem(
                        data: data,
                        fileName: "vault_\(UUID().uuidString.prefix(8)).\(ext)",
                        mediaType: mediaType,
                        senderID: container.sessionService.currentUserId ?? "",
                        vaultDataSource: vaultDataSource,
                        mediaManager: container.mediaManager
                    )
                }
            }
        }
    }
}

// MARK: - Vault Item Card

struct VaultItemCard: View {
    let item: VaultItem
    let colorScheme: ColorScheme
    var onDelete: () -> Void = {}
    var onShare: () -> Void = {}

    @State private var thumbnail: UIImage?

    /// Remaining time until expiration (if applicable).
    private var expiryText: String? {
        let now = Date()
        guard item.createdAt > Date.distantPast else { return nil }
        let secondsSinceCreation = now.timeIntervalSince(item.createdAt)
        // Default TTL: 30 days (2_592_000 seconds)
        let ttl: TimeInterval = 30 * 24 * 3600
        let remaining = ttl - secondsSinceCreation
        guard remaining > 0 else { return "Expired" }

        let days = Int(remaining / 86400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)

        if days > 0 {
            return "Expires in \(days)d"
        }
        return "Expires in \(hours)h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
            // Thumbnail / Icon area
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: SanchrRadius.sm)
                    .fill(Color.sanchrSurface(colorScheme))
                    .frame(height: 140)
                    .overlay {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))
                        } else {
                            Image(systemName: item.type.systemImage)
                                .font(.largeTitle)
                                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                        }
                    }
                    .clipped()

                // Type badge
                HStack(spacing: SanchrSpacing.xxxs) {
                    Text(item.type.rawValue.capitalized)
                        .font(SanchrTypography.micro)
                        .foregroundColor(.white)
                        .padding(.horizontal, SanchrSpacing.xs)
                        .padding(.vertical, SanchrSpacing.xxxs)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                }
                .padding(SanchrSpacing.xs)

                // Video play button overlay
                if item.type == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))

            // Item info
            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                Text(item.name)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    .lineLimit(1)

                HStack {
                    Text(item.formattedSize)
                        .font(SanchrTypography.micro)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))

                    Spacer()

                    if let expiry = expiryText {
                        Text(expiry)
                            .font(SanchrTypography.micro)
                            .foregroundColor(.sanchrError)
                    }
                }
            }

            // Action buttons
            HStack(spacing: SanchrSpacing.xs) {
                Button {
                    // Save to device
                } label: {
                    HStack(spacing: SanchrSpacing.xxxs) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption2)
                        Text("Save")
                            .font(SanchrTypography.micro)
                    }
                    .foregroundColor(.sanchrPrimary)
                    .padding(.horizontal, SanchrSpacing.xs)
                    .padding(.vertical, SanchrSpacing.xxs)
                    .background(Color.sanchrPrimary.opacity(0.1))
                    .clipShape(Capsule())
                }

                Button(action: onShare) {
                    HStack(spacing: SanchrSpacing.xxxs) {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.caption2)
                        Text("Share")
                            .font(SanchrTypography.micro)
                    }
                    .foregroundColor(.sanchrPrimary)
                    .padding(.horizontal, SanchrSpacing.xs)
                    .padding(.vertical, SanchrSpacing.xxs)
                    .background(Color.sanchrPrimary.opacity(0.1))
                    .clipShape(Capsule())
                }

                Spacer()
            }
        }
        .sanchrCard()
        .contextMenu {
            Button(action: onShare) {
                Label("Share", systemImage: "arrowshape.turn.up.right")
            }
            Button {
                // Save to device
            } label: {
                Label("Save to Device", systemImage: "square.and.arrow.down")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .task {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: item)
        }
    }
}
