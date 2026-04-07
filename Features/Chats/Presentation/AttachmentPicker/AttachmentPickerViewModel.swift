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
    @Published private(set) var selectedRecentIDs: Set<String> = []
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
        if selectedRecentIDs.contains(id) {
            selectedRecentIDs.remove(id)
            if selectedRecentIDs.isEmpty { exitMultiSelect() }
        } else {
            selectedRecentIDs.insert(id)
        }
    }

    func didConfirmRecentSelection() async {
        let ids = Array(selectedRecentIDs)
        exitMultiSelect()
        var items: [PickedMedia] = []
        for id in ids {
            if let m = await photos.loadPickedMedia(assetID: id) { items.append(m) }
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
