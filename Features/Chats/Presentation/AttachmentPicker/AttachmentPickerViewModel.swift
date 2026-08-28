import Foundation
import Combine
import SanchrShared

@MainActor
protocol PhotosSourceProviding: AnyObject {
    func currentPermission() -> PhotoPermission
    func requestPermission() async -> PhotoPermission
    func fetchRecents() -> [RecentPhoto]
    func loadPickedMedia(assetID: String) async -> PickedMedia?
}

extension PhotosLibrarySource: PhotosSourceProviding {}

@MainActor
final class AttachmentPickerViewModel: ObservableObject {

    private let photos: PhotosSourceProviding
    private let debounceWindow: TimeInterval

    @Published private(set) var recents: [RecentPhoto] = []
    @Published private(set) var isLoadingRecents = false
    /// Ordered deliberately. This was a `Set`, and `didConfirmRecentSelection`
    /// sent `Array(set)` — an order unrelated to what the user tapped, and one
    /// that Swift's per-process hash seed varies between launches, so the same
    /// photos arrived shuffled differently each run.
    @Published private(set) var selectedRecentIDs: [String] = []

    /// Ceiling on one batch. Each photo costs a sequential load and a
    /// sequential send, so an unbounded selection stalls the sheet with no way
    /// out. Matches WhatsApp.
    static let selectionLimit = 30
    @Published private(set) var isMultiSelecting = false
    @Published private(set) var photoPermission: PhotoPermission = .notDetermined
    @Published var transientError: String?

    var onIntent: ((AttachmentIntent) -> Void)?

    private var lastEmitAt: Date?

    init(photos: PhotosSourceProviding, debounceWindow: TimeInterval = 0.3) {
        self.photos = photos
        self.debounceWindow = debounceWindow
        self.photoPermission = photos.currentPermission()
    }

    func didAppear() {
        Task { @MainActor in
            if photoPermission == .notDetermined {
                photoPermission = await photos.requestPermission()
            }
            if photoPermission == .authorized || photoPermission == .limited {
                isLoadingRecents = true
                let list = photos.fetchRecents()
                self.recents = list
                isLoadingRecents = false
            }
        }
    }

    func didDisappear() { exitMultiSelect() }

    func didTapRecentPhoto(id: String) async {
        if isMultiSelecting {
            didToggleMultiSelect(id: id)
            return
        }
        guard !isDebounced() else { return }
        guard let media = await photos.loadPickedMedia(assetID: id) else {
            transientError = "Couldn't load photo"
            return
        }
        emit(.photoLibrary([media]))
    }

    func didLongPressRecent(id: String) {
        isMultiSelecting = true
        selectedRecentIDs = [id]
    }

    func didToggleMultiSelect(id: String) {
        if let existing = selectedRecentIDs.firstIndex(of: id) {
            selectedRecentIDs.remove(at: existing)
            if selectedRecentIDs.isEmpty { exitMultiSelect() }
        } else {
            guard selectedRecentIDs.count < Self.selectionLimit else {
                transientError = "You can send up to \(Self.selectionLimit) photos at once"
                return
            }
            selectedRecentIDs.append(id)
        }
    }

    func didConfirmRecentSelection() async {
        let ids = selectedRecentIDs
        exitMultiSelect()

        var items: [PickedMedia] = []
        var failed = 0
        for id in ids {
            if let m = await photos.loadPickedMedia(assetID: id) {
                items.append(m)
            } else {
                failed += 1
            }
        }

        // A photo that fails to load used to be dropped in silence: you picked
        // five, three arrived, and nothing said so. Report the shortfall — and
        // if every one failed, say that rather than closing as if sent.
        if failed > 0 {
            transientError =
                items.isEmpty
                ? "Couldn't load those photos"
                : "Couldn't load \(failed) of \(ids.count) photos — sending the rest"
        }

        guard !items.isEmpty else { return }
        emit(.photoLibrary(items))
    }

    func didCancelMultiSelect() { exitMultiSelect() }

    private func exitMultiSelect() {
        isMultiSelecting = false
        selectedRecentIDs.removeAll()
    }

    func receive(_ intent: AttachmentIntent) { emit(intent) }

    func seedRecents(_ list: [RecentPhoto]) { self.recents = list }

    private func isDebounced() -> Bool {
        let now = Date()
        if let last = lastEmitAt, now.timeIntervalSince(last) < debounceWindow { return true }
        lastEmitAt = now
        return false
    }

    private func emit(_ intent: AttachmentIntent) {
        onIntent?(intent)
    }
}
