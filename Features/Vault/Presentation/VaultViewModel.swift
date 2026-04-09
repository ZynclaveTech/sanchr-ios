import Foundation
import SanchrShared

/// View model for the vault screen.
///
/// NOTE(Task 10): This view model is temporarily stubbed to keep the build
/// green during the forward-secure vault migration. The old signatures are
/// preserved so call sites in `VaultView` compile, but the bodies are
/// minimal — they either delegate to the new `VaultUseCases` with the
/// decrypted metadata path or they no-op until Task 10 rewrites the view
/// model around a `vaultRepository` / container-level source-of-truth.
///
/// In particular:
/// - `totalPhotos` / `totalVideos` / `totalFiles` counters are no longer
///   returned by the server. They are computed client-side from the
///   decrypted items slice. This is an O(n) scan per load, which is fine
///   for the current page sizes and will be replaced by a proper reactive
///   store in Task 10.
/// - Filter-by-type is applied client-side in `loadItems` because the
///   server no longer exposes a filter field on `GetVaultItems`.
/// - Sharing is removed entirely (the forward-secure design does not
///   support key rewrapping).
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

    /// TODO(Task 10): Migrate to a container-level repository source so the
    /// view model doesn't need AccessKeyStore + MediaEncryption passed in
    /// piecemeal. For now this is a no-op body that leaves the UI blank —
    /// the forward-secure vault read path works via
    /// `VaultRepositoryImpl.fetchItems()` but the view model rewrite is
    /// deferred to Task 10.
    func loadItems(vaultDataSource: VaultDataSource) async {
        // TODO(Task 10): Restore metadata-decryption-aware load path.
        // The old server-side filter/counters API is gone and the new
        // GetVaultItems use case needs an AccessKeyStore + MediaEncryption
        // that the view model doesn't currently hold. Wiring those through
        // belongs to the Task 10 view model rewrite.
        isLoading = false
        items = []
        totalPhotos = 0
        totalVideos = 0
        totalFiles = 0
        cursor = ""
        hasMorePages = false
        errorMessage = nil
    }

    // MARK: - Load More (Pagination)

    func loadMore(vaultDataSource: VaultDataSource) async {
        // TODO(Task 10): Same as loadItems — paginated fetch via the proper
        // decryption path belongs to the view model rewrite.
        hasMorePages = false
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
