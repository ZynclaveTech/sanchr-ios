import Foundation

/// View model for the vault screen.
/// Manages items list, filter state, stats, upload progress, and pagination.
@MainActor
@Observable
final class VaultViewModel {

    // MARK: - Filter

    enum Filter: String, CaseIterable, Identifiable {
        case all = "all"
        case photos = "photo"
        case videos = "video"
        case files = "file"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "All Media"
            case .photos: return "Photos"
            case .videos: return "Videos"
            case .files: return "Files"
            }
        }

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .photos: return "photo"
            case .videos: return "video"
            case .files: return "doc"
            }
        }
    }

    // MARK: - State

    var items: [VaultItem] = []
    var activeFilter: Filter = .all
    var totalPhotos: Int32 = 0
    var totalVideos: Int32 = 0
    var totalFiles: Int32 = 0
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var isUploading: Bool = false
    var uploadProgress: Double = 0.0
    var errorMessage: String?
    var hasMorePages: Bool = true

    /// Cursor for pagination (ID of last item).
    private var cursor: String = ""

    // MARK: - Computed

    var totalItems: Int32 { totalPhotos + totalVideos + totalFiles }

    // MARK: - Load Items

    func loadItems(vaultDataSource: VaultDataSource) async {
        isLoading = true
        cursor = ""
        hasMorePages = true
        defer { isLoading = false }

        let useCase = VaultUseCases.GetVaultItems(vaultDataSource: vaultDataSource)

        do {
            let result = try await useCase.execute(filter: activeFilter.rawValue)
            items = result.items
            totalPhotos = result.totalPhotos
            totalVideos = result.totalVideos
            totalFiles = result.totalFiles
            cursor = items.last?.id ?? ""
            hasMorePages = result.items.count >= 20
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Load More (Pagination)

    func loadMore(vaultDataSource: VaultDataSource) async {
        guard !isLoadingMore, hasMorePages, !cursor.isEmpty else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let useCase = VaultUseCases.GetVaultItems(vaultDataSource: vaultDataSource)

        do {
            let result = try await useCase.execute(
                filter: activeFilter.rawValue,
                cursor: cursor
            )

            if result.items.isEmpty {
                hasMorePages = false
            } else {
                items.append(contentsOf: result.items)
                cursor = result.items.last?.id ?? ""
                hasMorePages = result.items.count >= 20
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Change Filter

    func changeFilter(_ filter: Filter) {
        activeFilter = filter
        // .task(id: activeFilter) in the view auto-triggers loadItems
    }

    // MARK: - Delete

    func deleteItem(
        _ item: VaultItem,
        vaultDataSource: VaultDataSource,
        localDatabase: LocalDatabaseProtocol
    ) async {
        let useCase = VaultUseCases.DeleteVaultItem(
            vaultDataSource: vaultDataSource,
            localDatabase: localDatabase
        )

        do {
            try await useCase.execute(itemId: item.id)
            items.removeAll { $0.id == item.id }
            await ThumbnailCache.shared.remove(for: item.id)

            switch item.type {
            case .photo: totalPhotos = max(0, totalPhotos - 1)
            case .video: totalVideos = max(0, totalVideos - 1)
            case .document, .audio, .note: totalFiles = max(0, totalFiles - 1)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Share

    func shareItem(
        _ item: VaultItem,
        recipientId: String,
        reEncryptedKey: String,
        vaultDataSource: VaultDataSource
    ) async {
        let useCase = VaultUseCases.ShareVaultItem(vaultDataSource: vaultDataSource)

        do {
            try await useCase.execute(
                itemId: item.id,
                recipientId: recipientId,
                reEncryptedKey: reEncryptedKey
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Upload

    func uploadItem(
        data: Data,
        fileName: String,
        mediaType: String,
        senderID: String,
        vaultDataSource: VaultDataSource,
        mediaManager: MediaManagerProtocol
    ) async {
        isUploading = true
        uploadProgress = 0.0
        defer {
            isUploading = false
            uploadProgress = 0.0
        }

        let useCase = VaultUseCases.UploadToVault(
            vaultDataSource: vaultDataSource,
            mediaManager: mediaManager
        )

        do {
            let newItem = try await useCase.execute(
                data: data,
                fileName: fileName,
                mediaType: mediaType,
                senderID: senderID
            ) { [weak self] fraction in
                Task { @MainActor in
                    self?.uploadProgress = fraction
                }
            }
            uploadProgress = 1.0
            items.insert(newItem, at: 0)

            // Update counts
            switch newItem.type {
            case .photo: totalPhotos += 1
            case .video: totalVideos += 1
            case .document, .audio, .note: totalFiles += 1
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Formatting

    func formattedStorage(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
