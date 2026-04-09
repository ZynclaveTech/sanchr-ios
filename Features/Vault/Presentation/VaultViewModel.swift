import Foundation
import SanchrShared

/// View model for the vault screen.
///
/// Drives the vault UI's list/filter/upload/delete state. The load path uses
/// `VaultUseCases.GetVaultItems` which decrypts each item's metadata envelope
/// client-side using the per-item `AccessK_vault` from `AccessKeyStore`.
/// Sealed items (missing access key — i.e. restored from a cross-device
/// backup) are filtered out by the use case layer and never reach the UI.
///
/// Per-type counters (`totalPhotos` etc.) are computed client-side from the
/// loaded items array because the forward-secure server response does not
/// include them (name/type/size are encrypted in `encrypted_metadata` and
/// only the client can see them).
///
/// Sharing is removed entirely — the forward-secure design does not support
/// key re-wrapping.
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

    /// Pagination cursor (opaque, provided by the server).
    private var cursor: String = ""

    // MARK: - Computed

    var totalItems: Int32 { totalPhotos + totalVideos + totalFiles }

    // MARK: - Load Items

    /// Loads the first page of vault items. Decrypts each item's metadata
    /// envelope client-side via `VaultUseCases.GetVaultItems`. Sealed items
    /// (missing AccessK_vault) are filtered out by the use case layer.
    func loadItems(
        vaultDataSource: VaultDataSource,
        accessKeyStore: AccessKeyStoreProtocol,
        mediaEncryption: MediaEncryptionProtocol
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let useCase = VaultUseCases.GetVaultItems(
            vaultDataSource: vaultDataSource,
            accessKeyStore: accessKeyStore,
            mediaEncryption: mediaEncryption
        )

        do {
            let result = try await useCase.execute(limit: 100, cursor: "")
            items = result.items
            cursor = result.nextCursor
            hasMorePages = !cursor.isEmpty
            recomputeCounters()
        } catch {
            errorMessage = error.localizedDescription
            items = []
            hasMorePages = false
        }
    }

    // MARK: - Load More (Pagination)

    func loadMore(
        vaultDataSource: VaultDataSource,
        accessKeyStore: AccessKeyStoreProtocol,
        mediaEncryption: MediaEncryptionProtocol
    ) async {
        guard !isLoadingMore, hasMorePages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let useCase = VaultUseCases.GetVaultItems(
            vaultDataSource: vaultDataSource,
            accessKeyStore: accessKeyStore,
            mediaEncryption: mediaEncryption
        )

        do {
            let result = try await useCase.execute(limit: 100, cursor: cursor)
            items.append(contentsOf: result.items)
            cursor = result.nextCursor
            hasMorePages = !cursor.isEmpty
            recomputeCounters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private helpers

    /// Recomputes per-type counters from the loaded items array. The server
    /// no longer returns per-type counts; we derive them client-side from
    /// the decrypted items slice.
    private func recomputeCounters() {
        var photos: Int32 = 0
        var videos: Int32 = 0
        var files: Int32 = 0
        for item in items {
            switch item.type {
            case .photo: photos += 1
            case .video: videos += 1
            case .document, .audio, .note: files += 1
            }
        }
        totalPhotos = photos
        totalVideos = videos
        totalFiles = files
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
            try await useCase.execute(vaultItemId: item.id)
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

    // MARK: - Upload

    /// TODO(Task 10): The view model still drives the upload path, but the
    /// `senderID` parameter is gone (the new forward-secure vault doesn't
    /// need it — the manual upload path derives its own AccessK_vault from
    /// the device master secret). The VaultView call sites still pass
    /// `senderID:` for now; that parameter is accepted and ignored so the
    /// view compiles. Task 10 removes the parameter from the call sites.
    func uploadItem(
        data: Data,
        fileName: String,
        mediaType: String,
        senderID: String,
        vaultDataSource: VaultDataSource,
        mediaManager: MediaManagerProtocol
    ) async {
        _ = senderID  // accepted and ignored — see docstring
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
                mediaType: mediaType
            ) { [weak self] fraction in
                Task { @MainActor in
                    self?.uploadProgress = fraction
                }
            }
            uploadProgress = 1.0
            items.insert(newItem, at: 0)

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
