import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SanchrShared

@MainActor
struct VaultView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = VaultViewModel()
    @State private var showAddSheet = false
    @State private var selectedPhotoItem: PhotosPickerItem?
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
        .navigationTitle("Vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select") {}
                    Button("Sort") {}
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addToVaultSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .spreadsheet, .presentation, .data, .archive, .item],
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
                        vaultDataSource: vaultDataSource,
                        mediaManager: container.mediaManager
                    )
                }
            }
        }
        .task(id: viewModel.activeFilter) {
            await viewModel.loadItems(
                vaultDataSource: vaultDataSource,
                accessKeyStore: container.accessKeyStore,
                mediaEncryption: container.mediaEncryption
            )
        }
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
        if viewModel.isLoading {
            ProgressView()
                .tint(.sanchrPrimary)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else if viewModel.items.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.items) { item in
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
                        onShare: {}
                    )
                    .onAppear {
                        if item.id == viewModel.items.last?.id {
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

                if viewModel.isUploading {
                    uploadProgressView
                }

                if viewModel.isLoadingMore {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xEEF2FF), Color(hex: 0xECFEFF)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
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

    private var uploadProgressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Uploading to Vault")
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)
            ProgressView(value: viewModel.uploadProgress)
                .tint(.sanchrPrimary)
            Text("\(Int(viewModel.uploadProgress * 100))% complete")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(18)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                    selection: $selectedPhotoItem,
                    matching: .any(of: [.images, .videos])
                ) {
                    VaultSheetRow(
                        icon: "photo.on.rectangle.fill",
                        tint: SanchrColors.primary,
                        title: "Photo or Video",
                        subtitle: "Select from your library"
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
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }

            Task {
                let isVideo = newValue.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
                let ext = isVideo ? "mp4" : "jpg"
                let mediaType = isVideo ? "video" : "photo"

                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    showAddSheet = false
                    await viewModel.uploadItem(
                        data: data,
                        fileName: "vault_\(UUID().uuidString.prefix(8)).\(ext)",
                        mediaType: mediaType,
                        vaultDataSource: vaultDataSource,
                        mediaManager: container.mediaManager
                    )
                }
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

    @State private var thumbnail: UIImage?

    private var expiryText: String {
        let remaining = (30 * 24 * 3600) - Date().timeIntervalSince(item.createdAt)
        guard remaining > 0 else { return "Expired" }
        let hours = Int(remaining / 3600)
        return "Expires in \(hours)h"
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

                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(ttlText)
                        .font(SanchrTypography.captionSmall)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(iconTint)
                .clipShape(Capsule())
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                        Button("Save") {}
                        Button("Share", action: onShare)
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
                        VaultActionButton(icon: "square.and.arrow.down", title: "Save", tint: SanchrColors.primary)
                        VaultActionButton(icon: "square.and.arrow.up", title: "Share", tint: SanchrExportColors.textSecondary)
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

    private var ttlText: String {
        switch item.type {
        case .photo:
            return "24h"
        case .video:
            return "48h"
        case .document:
            return "72h"
        case .audio:
            return "24h"
        case .note:
            return "12h"
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

private struct VaultActionButton: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.sanchrPrimary)
            Text(title)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
    }
}
