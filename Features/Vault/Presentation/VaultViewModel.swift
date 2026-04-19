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

    // MARK: - Sort

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest
        case oldest
        case nameAscending
        case nameDescending
        case sizeLargest
        case sizeSmallest

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .nameAscending: return "Name (A → Z)"
            case .nameDescending: return "Name (Z → A)"
            case .sizeLargest: return "Size (largest)"
            case .sizeSmallest: return "Size (smallest)"
            }
        }
    }

    // MARK: - Share State

    /// State for the save/share state machine. `nil` means idle.
    ///
    /// Flow A (`requestSave`) uses `.saving` and `.exportingToFiles`.
    /// Flow B / B1 / B2 (`requestShare`) uses `.choosingDestination`,
    /// `.pickingConversation`, `.confirmingLargeReupload`,
    /// `.sendingToChat`, `.preparingShare`, and `.externalSharing`.
    enum ShareState: Sendable {
        /// Flow A: downloading + writing temp file for a photo/video → Photos.
        case saving(VaultItem)
        /// Flow A: temp file ready, showing the Files export picker.
        case exportingToFiles(VaultItem, tempURL: URL)

        /// Flow B: showing the two-row share destination chooser.
        case choosingDestination(VaultItem)

        /// Flow B1: showing the conversation picker.
        case pickingConversation(VaultItem)
        /// Flow B1: showing the 25MB re-upload confirmation alert.
        case confirmingLargeReupload(
            VaultItem,
            conversationId: String,
            conversationName: String,
            sizeBytes: Int64
        )
        /// Flow B1: sending to a chat (in flight).
        case sendingToChat(
            VaultItem,
            conversationId: String,
            conversationName: String
        )

        /// Flow B2: coordinator is downloading + writing the temp file.
        case preparingShare(VaultItem)
        /// Flow B2: temp file ready, showing the iOS activity view.
        case externalSharing(VaultItem, tempURL: URL)
    }

    // MARK: - State

    var items: [VaultItem] = []
    var activeFilter: Filter = .all
    var activeSort: SortOrder = .newest
    var totalPhotos: Int32 = 0
    var totalVideos: Int32 = 0
    var totalFiles: Int32 = 0
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var errorMessage: String?
    var hasMorePages: Bool = true

    /// When true, the list enters multi-select mode: taps toggle the
    /// item's presence in `selectedItemIds` instead of opening it, and
    /// the toolbar offers a bulk-delete action.
    var isSelectMode: Bool = false

    /// Vault item IDs currently selected in `isSelectMode`.
    var selectedItemIds: Set<String> = []

    /// Active and queued uploads. Drives the per-upload progress cards in
    /// the vault view. Uploads are removed from this array once they
    /// complete (successfully or unrecoverably).
    var uploads: [UploadTask] = []

    /// Max number of uploads running in parallel. The remainder queue in
    /// `.pending` state until a slot frees up. 3 balances "feels responsive"
    /// against "doesn't saturate the uplink on mobile networks".
    private let uploadConcurrencyLimit = 3

    /// Pagination cursor (opaque, provided by the server).
    private var cursor: String = ""

    /// Current position in the save/share state machine. `nil` means
    /// idle. Flow A drives `.saving` / `.exportingToFiles`; Flow B
    /// drives the rest.
    var shareState: ShareState?

    /// Transient toast shown in the vault view after a save/share
    /// completes. Consumed exactly once via `takeShareCompletionToast`.
    var shareCompletionToast: String?

    // MARK: - Computed

    var totalItems: Int32 { totalPhotos + totalVideos + totalFiles }

    /// Items filtered by `activeFilter` and ordered by `activeSort`.
    /// Drives the vault list UI so filter taps and sort changes are purely
    /// client-side (the forward-secure server cannot filter or sort on
    /// encrypted metadata).
    var filteredItems: [VaultItem] {
        let filtered: [VaultItem]
        switch activeFilter {
        case .all:
            filtered = items
        case .photos:
            filtered = items.filter { $0.type == .photo }
        case .videos:
            filtered = items.filter { $0.type == .video }
        case .files:
            // "Files" = everything that isn't a photo or video: documents,
            // audio, notes. The filter tab is a coarse bucket for the UI.
            filtered = items.filter { item in
                switch item.type {
                case .document, .audio, .note: return true
                case .photo, .video: return false
                }
            }
        }

        switch activeSort {
        case .newest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        case .nameAscending:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeLargest:
            return filtered.sorted { $0.sizeBytes > $1.sizeBytes }
        case .sizeSmallest:
            return filtered.sorted { $0.sizeBytes < $1.sizeBytes }
        }
    }

    /// `true` while any upload is pending or in progress. Used by the view
    /// to show/suppress the empty-state placeholder during the first batch.
    var isUploading: Bool {
        uploads.contains { task in
            switch task.state {
            case .pending, .uploading: return true
            case .failed: return false
            }
        }
    }

    // MARK: - UploadTask

    struct UploadTask: Identifiable, Sendable {
        enum State: Sendable {
            case pending
            case uploading(progress: Double)
            case failed(message: String)
        }

        let id: UUID
        let fileName: String
        let mediaType: String
        var state: State
    }

    /// Spec for a file the user has selected for upload. The `data` is loaded
    /// eagerly (PhotosPicker / fileImporter both hand us Data) so the upload
    /// dispatcher can schedule each item independently.
    struct UploadSpec: Sendable {
        let fileName: String
        let mediaType: String
        let data: Data
    }

    // MARK: - Load Items

    /// Loads the first page of vault items. Decrypts each item's metadata
    /// envelope client-side via `VaultUseCases.GetVaultItems`. Sealed items
    /// (missing AccessK_vault) are filtered out by the use case layer.
    func loadItems(
        vaultDataSource: VaultDataSource,
        accessKeyStore: AccessKeyStoreProtocol,
        mediaEncryption: MediaEncryptionProtocol
    ) async {
        // Only show the full-screen spinner on the very first load (no items yet).
        // On subsequent refreshes keep the existing items visible so they don't
        // vanish while the network round-trip completes.
        let isInitialLoad = items.isEmpty
        if isInitialLoad { isLoading = true }
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
            // Only clear items on initial load failure — on refresh failure
            // keep the stale items visible so the user doesn't lose context.
            if isInitialLoad { items = [] }
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

    // MARK: - Save (Flow A)

    /// Flow A entry point. Auto-routes by type:
    /// - `.photo` / `.video` → download + PhotosSaver
    /// - `.document` / `.audio` / `.note` → download + write temp file,
    ///   set shareState to `.exportingToFiles` so the view presents
    ///   `UIDocumentPickerViewController(forExporting:)`.
    ///
    /// No-op if `shareState != nil` (a save or share is already in
    /// flight). The concurrency guard prevents double-taps from
    /// re-downloading the same bytes.
    ///
    /// Dependencies are passed per-call rather than injected at init
    /// to match the existing style of `loadItems` / `loadMore`. Task 6
    /// extends this pattern for Flow B.
    func requestSave(
        _ item: VaultItem,
        vaultRepository: VaultRepositoryProtocol,
        photosSaver: PhotosSaving
    ) async {
        guard shareState == nil else {
            SanchrLogger.vault.info("requestSave: ignored — shareState is set")
            return
        }

        shareState = .saving(item)
        // Clear the .saving state on exit via defer. If we transition
        // to .exportingToFiles before returning, that assignment takes
        // precedence and the guard below leaves it alone.
        defer {
            if case .saving = shareState { shareState = nil }
        }

        let data: Data
        do {
            data = try await vaultRepository.downloadItem(id: item.id)
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.vault.error("requestSave: download failed: \(error.localizedDescription)")
            return
        }

        switch item.type {
        case .photo, .video:
            do {
                try await photosSaver.save(
                    data: data,
                    mediaType: item.type,
                    suggestedFilename: item.name.isEmpty ? "vault-item" : item.name
                )
                shareCompletionToast = "Saved to Photos"
            } catch let photosError as PhotosSaverError {
                switch photosError {
                case .unsupportedMediaType:
                    // Defensive fallthrough: shouldn't happen for
                    // .photo/.video, but if it does, route to Files
                    // instead of surfacing a confusing error.
                    routeToFilesExport(item: item, data: data)
                case .permissionDenied, .tempWriteFailed, .saveFailed:
                    errorMessage = photosError.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }

        case .document, .audio, .note:
            routeToFilesExport(item: item, data: data)
        }
    }

    /// Writes the downloaded bytes to a temp file and transitions to
    /// `.exportingToFiles`. The view presents
    /// `UIDocumentPickerViewController(forExporting:)` which takes
    /// ownership of the temp URL (iOS copies on import).
    private func routeToFilesExport(item: VaultItem, data: Data) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-save-\(UUID().uuidString)", isDirectory: true)
        let filename = item.name.isEmpty ? "vault-item" : item.name
        let tempURL = tempDir.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(
                at: tempDir,
                withIntermediateDirectories: true
            )
            try data.write(to: tempURL, options: .atomic)
        } catch {
            errorMessage = "Couldn't prepare file for save: \(error.localizedDescription)"
            return
        }

        shareState = .exportingToFiles(item, tempURL: tempURL)
    }

    /// Called by the view when `UIDocumentPickerViewController`
    /// dismisses (success or cancel). Clears the share state and
    /// deletes the temp file's enclosing directory.
    func didFinishFilesExport(for item: VaultItem, tempURL: URL, success: Bool) {
        let tempDir = tempURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: tempDir)
        if success {
            shareCompletionToast = "Saved"
        }
        shareState = nil
    }

    /// Consumes and returns the transient completion toast. Called by
    /// the view each render; the toast is displayed for a couple of
    /// seconds and then cleared.
    func takeShareCompletionToast() -> String? {
        let toast = shareCompletionToast
        shareCompletionToast = nil
        return toast
    }

    // MARK: - Share (Flow B)

    /// Flow B entry point. Shows the two-row destination chooser.
    ///
    /// No-op if another save or share is already in flight (guards
    /// against double-tap and prevents two competing state machines).
    func requestShare(_ item: VaultItem) {
        guard shareState == nil else {
            SanchrLogger.vault.info("requestShare: ignored — shareState is set")
            return
        }
        shareState = .choosingDestination(item)
    }

    /// User picked "Share in chat" in the destination chooser.
    /// Transitions to the conversation picker.
    func chooseShareInChat(for item: VaultItem) {
        shareState = .pickingConversation(item)
    }

    /// User picked "Share outside Sanchr" in the destination chooser.
    /// Downloads via the coordinator and transitions to
    /// `.externalSharing` with a temp URL. The view presents
    /// `VaultActivityView` bound to that URL.
    ///
    /// On download failure, surfaces via `errorMessage` and clears the
    /// state.
    func chooseShareOutside(
        for item: VaultItem,
        sharingCoordinator: VaultSharingCoordinating
    ) async {
        shareState = .preparingShare(item)
        do {
            let tempURL = try await sharingCoordinator.prepareForExternalShare(item: item)
            shareState = .externalSharing(item, tempURL: tempURL)
        } catch {
            errorMessage = error.localizedDescription
            shareState = nil
        }
    }

    /// Called by the view when `UIActivityViewController` dismisses.
    /// Cleans up the temp file via the coordinator and clears the
    /// share state. Sets the completion toast only on success.
    func didFinishExternalShare(
        for item: VaultItem,
        tempURL: URL,
        completed: Bool,
        sharingCoordinator: VaultSharingCoordinating
    ) {
        Task {
            await sharingCoordinator.cleanupTempFile(at: tempURL)
        }
        if completed {
            shareCompletionToast = "Shared"
        }
        shareState = nil
    }

    /// User picked a conversation in the picker. Checks size against
    /// the 25 MB threshold; if under, proceeds directly; if over,
    /// transitions to `.confirmingLargeReupload`.
    func confirmConversation(
        conversationId: String,
        conversationName: String,
        for item: VaultItem,
        sharingCoordinator: VaultSharingCoordinating
    ) async {
        let threshold: Int64 = 25 * 1024 * 1024
        if item.sizeBytes > threshold {
            shareState = .confirmingLargeReupload(
                item,
                conversationId: conversationId,
                conversationName: conversationName,
                sizeBytes: item.sizeBytes
            )
            return
        }
        await performShareToChat(
            item: item,
            conversationId: conversationId,
            conversationName: conversationName,
            sharingCoordinator: sharingCoordinator
        )
    }

    /// User confirmed the 25 MB alert. Proceeds with the share.
    /// Reads the item + conversation info directly out of the
    /// `.confirmingLargeReupload` state so the caller doesn't have to
    /// re-pass them.
    func confirmLargeReupload(
        sharingCoordinator: VaultSharingCoordinating
    ) async {
        guard case .confirmingLargeReupload(let item, let cid, let cname, _) = shareState else {
            return
        }
        await performShareToChat(
            item: item,
            conversationId: cid,
            conversationName: cname,
            sharingCoordinator: sharingCoordinator
        )
    }

    /// User cancelled the 25 MB alert. Returns to the conversation
    /// picker so they can pick a different chat (or cancel entirely).
    func cancelLargeReupload() {
        guard case .confirmingLargeReupload(let item, _, _, _) = shareState else {
            return
        }
        shareState = .pickingConversation(item)
    }

    /// User dismissed the destination chooser or the conversation
    /// picker without picking anything. Clears share state entirely.
    func cancelShare() {
        shareState = nil
    }

    // MARK: - Private share helpers

    /// Single choke point for calling the coordinator's shareToChat.
    /// Both the ≤25MB direct path and the >25MB confirmed path route
    /// through here so the toast-message and state-clear logic stays
    /// DRY.
    private func performShareToChat(
        item: VaultItem,
        conversationId: String,
        conversationName: String,
        sharingCoordinator: VaultSharingCoordinating
    ) async {
        shareState = .sendingToChat(
            item,
            conversationId: conversationId,
            conversationName: conversationName
        )
        do {
            _ = try await sharingCoordinator.shareToChat(
                item: item,
                conversationId: conversationId
            )
            shareCompletionToast = "Sent to \(conversationName)"
            shareState = nil
        } catch {
            errorMessage = error.localizedDescription
            shareState = nil
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
        // Filter application is purely client-side via the filteredItems
        // computed property — no server round-trip needed.
    }

    // MARK: - Sort

    func changeSort(_ order: SortOrder) {
        activeSort = order
    }

    // MARK: - Select Mode

    /// Enter multi-select mode. Any existing selection is cleared.
    func enterSelectMode() {
        isSelectMode = true
        selectedItemIds = []
    }

    /// Exit multi-select mode. Clears the current selection.
    func exitSelectMode() {
        isSelectMode = false
        selectedItemIds = []
    }

    /// Toggle whether `id` is in the current selection. No-op outside
    /// select mode.
    func toggleSelection(for id: String) {
        guard isSelectMode else { return }
        if selectedItemIds.contains(id) {
            selectedItemIds.remove(id)
        } else {
            selectedItemIds.insert(id)
        }
    }

    /// Select all currently-visible (filtered) items.
    func selectAllVisible() {
        guard isSelectMode else { return }
        selectedItemIds = Set(filteredItems.map(\.id))
    }

    /// Delete every item in the current selection. Each deletion runs
    /// through the same `DeleteVaultItem` use case as the single-item
    /// path so the server-side cleanup and local cache eviction stay in
    /// sync. Failures on individual items are swallowed into
    /// `errorMessage` but do not abort the batch.
    func deleteSelectedItems(
        vaultDataSource: VaultDataSource,
        localDatabase: LocalDatabaseProtocol
    ) async {
        guard !selectedItemIds.isEmpty else { return }
        let useCase = VaultUseCases.DeleteVaultItem(
            vaultDataSource: vaultDataSource,
            localDatabase: localDatabase
        )

        let idsToDelete = selectedItemIds
        var lastError: String?
        for id in idsToDelete {
            do {
                try await useCase.execute(vaultItemId: id)
                items.removeAll { $0.id == id }
                await ThumbnailCache.shared.remove(for: id)
            } catch {
                lastError = error.localizedDescription
            }
        }

        recomputeCounters()
        selectedItemIds = []
        isSelectMode = false
        if let lastError {
            errorMessage = lastError
        }
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

    /// Enqueue one or more uploads. Each spec becomes a pending `UploadTask`
    /// in the `uploads` array; the dispatcher keeps up to
    /// `uploadConcurrencyLimit` uploads in flight at once and drains the
    /// queue as slots free up.
    ///
    /// Safe to call while an earlier batch is still running — new specs are
    /// appended and the dispatcher picks them up on the next slot.
    func enqueueUploads(
        _ specs: [UploadSpec],
        vaultDataSource: VaultDataSource,
        mediaManager: MediaManagerProtocol
    ) async {
        guard !specs.isEmpty else { return }

        // Materialize pending tasks into the UI model first so the progress
        // cards appear immediately.
        let newTasks = specs.map { spec in
            UploadTask(
                id: UUID(),
                fileName: spec.fileName,
                mediaType: spec.mediaType,
                state: .pending
            )
        }
        uploads.append(contentsOf: newTasks)

        let useCase = VaultUseCases.UploadToVault(
            vaultDataSource: vaultDataSource,
            mediaManager: mediaManager
        )

        // Zip specs with their task IDs so the dispatcher can match
        // progress callbacks back to the UI row.
        let jobs = zip(newTasks.map(\.id), specs).map { (id, spec) in
            (id: id, spec: spec)
        }

        // Concurrency-bounded dispatcher. `withTaskGroup` gives us
        // structured concurrency, and the `pending.count < limit` / await
        // next() pattern is the canonical Swift idiom for a worker pool.
        await withTaskGroup(of: UploadOutcome.self) { group in
            var cursor = 0
            var inFlight = 0

            // Seed up to `uploadConcurrencyLimit` jobs.
            while cursor < jobs.count && inFlight < self.uploadConcurrencyLimit {
                let job = jobs[cursor]
                cursor += 1
                inFlight += 1
                self.markTaskUploading(id: job.id, progress: 0)
                group.addTask { [useCase] in
                    await Self.runSingleUpload(
                        id: job.id,
                        spec: job.spec,
                        useCase: useCase,
                        progressSink: { [weak self] fraction in
                            Task { @MainActor in
                                self?.markTaskUploading(id: job.id, progress: fraction)
                            }
                        }
                    )
                }
            }

            // Drain completions; refill slots as they free up.
            while let outcome = await group.next() {
                inFlight -= 1
                self.handleUploadOutcome(outcome)

                if cursor < jobs.count {
                    let job = jobs[cursor]
                    cursor += 1
                    inFlight += 1
                    self.markTaskUploading(id: job.id, progress: 0)
                    group.addTask { [useCase] in
                        await Self.runSingleUpload(
                            id: job.id,
                            spec: job.spec,
                            useCase: useCase,
                            progressSink: { [weak self] fraction in
                                Task { @MainActor in
                                    self?.markTaskUploading(id: job.id, progress: fraction)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    /// Dismiss a failed upload from the queue. Called by the view when the
    /// user taps the "dismiss" affordance on a failed-upload card.
    func dismissFailedUpload(id: UUID) {
        uploads.removeAll { task in
            if task.id == id, case .failed = task.state { return true }
            return false
        }
    }

    // MARK: - Upload helpers

    private enum UploadOutcome: Sendable {
        case success(id: UUID, item: VaultItem)
        case failure(id: UUID, message: String)
    }

    private static func runSingleUpload(
        id: UUID,
        spec: UploadSpec,
        useCase: VaultUseCases.UploadToVault,
        progressSink: @escaping @Sendable (Double) -> Void
    ) async -> UploadOutcome {
        do {
            let item = try await useCase.execute(
                data: spec.data,
                fileName: spec.fileName,
                mediaType: spec.mediaType,
                onProgress: progressSink
            )
            return .success(id: id, item: item)
        } catch {
            return .failure(id: id, message: error.localizedDescription)
        }
    }

    private func markTaskUploading(id: UUID, progress: Double) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        // Never downgrade from .failed to .uploading — a late progress
        // callback after failure should be a no-op.
        if case .failed = uploads[index].state { return }
        uploads[index].state = .uploading(progress: progress)
    }

    private func handleUploadOutcome(_ outcome: UploadOutcome) {
        switch outcome {
        case .success(let id, let item):
            // Remove the in-flight row and insert the real item into the
            // main list at the top.
            uploads.removeAll { $0.id == id }
            items.insert(item, at: 0)
            switch item.type {
            case .photo: totalPhotos += 1
            case .video: totalVideos += 1
            case .document, .audio, .note: totalFiles += 1
            }

        case .failure(let id, let message):
            // Leave the task visible in .failed state so the user can see
            // what broke and dismiss it. Also surface the error on the
            // shared errorMessage for a toast.
            if let index = uploads.firstIndex(where: { $0.id == id }) {
                uploads[index].state = .failed(message: message)
            }
            errorMessage = message
        }
    }

    // MARK: - Formatting

    func formattedStorage(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
