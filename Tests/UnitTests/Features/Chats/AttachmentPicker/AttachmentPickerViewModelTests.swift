import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class AttachmentPickerViewModelTests: XCTestCase {

    func test_singleTapRecent_emitsPhotoLibraryIntentWithOneItem() async throws {
        let vm = makeVM()
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a"), rp("b")])
        await vm.didTapRecentPhoto(id: "a")

        XCTAssertEqual(emitted.count, 1)
        if case .photoLibrary(let items) = emitted.first {
            XCTAssertEqual(items.count, 1)
        } else { XCTFail("Expected .photoLibrary") }
    }

    func test_longPressThenTap_entersMultiSelectAndDoesNotEmit() {
        let vm = makeVM()
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a"), rp("b")])
        vm.didLongPressRecent(id: "a")
        XCTAssertTrue(vm.isMultiSelecting)
        XCTAssertEqual(vm.selectedRecentIDs, ["a"])

        vm.didToggleMultiSelect(id: "b")
        XCTAssertEqual(vm.selectedRecentIDs, ["a", "b"])
        XCTAssertEqual(emitted.count, 0)
    }

    func test_confirmMultiSelect_emitsPhotoLibraryWithAllSelected() async {
        let vm = makeVM()
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a"), rp("b"), rp("c")])
        vm.didLongPressRecent(id: "a")
        vm.didToggleMultiSelect(id: "c")
        await vm.didConfirmRecentSelection()

        XCTAssertEqual(emitted.count, 1)
        if case .photoLibrary(let items) = emitted.first {
            XCTAssertEqual(items.count, 2)
        } else { XCTFail() }
        XCTAssertFalse(vm.isMultiSelecting)
        XCTAssertTrue(vm.selectedRecentIDs.isEmpty)
    }

    func test_debounce_collapsesRapidSingleTaps() async {
        let vm = makeVM()
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a")])
        await vm.didTapRecentPhoto(id: "a")
        await vm.didTapRecentPhoto(id: "a")  // within debounce window

        XCTAssertEqual(emitted.count, 1)
    }

    /// Selection used to be a `Set`, and confirming sent `Array(set)` — an
    /// order unrelated to the taps, and one Swift's per-process hash seed
    /// varies between launches, so the same photos arrived shuffled.
    func test_confirmMultiSelect_sendsInTapOrder() async {
        let vm = makeVM()
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a"), rp("b"), rp("c"), rp("d")])
        vm.didLongPressRecent(id: "c")
        vm.didToggleMultiSelect(id: "a")
        vm.didToggleMultiSelect(id: "d")
        vm.didToggleMultiSelect(id: "b")
        await vm.didConfirmRecentSelection()

        guard case .photoLibrary(let items) = emitted.first else { return XCTFail("no intent") }
        XCTAssertEqual(items.map(\.originalFilename), ["c", "a", "d", "b"])
    }

    /// Deselecting then reselecting puts a photo at the end, matching the
    /// numbered badges the user sees.
    func test_reselectingMovesToEndOfOrder() async {
        let vm = makeVM()
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a"), rp("b"), rp("c")])
        vm.didLongPressRecent(id: "a")
        vm.didToggleMultiSelect(id: "b")
        vm.didToggleMultiSelect(id: "c")
        vm.didToggleMultiSelect(id: "b")  // deselect
        vm.didToggleMultiSelect(id: "b")  // reselect
        await vm.didConfirmRecentSelection()

        guard case .photoLibrary(let items) = emitted.first else { return XCTFail("no intent") }
        XCTAssertEqual(items.map(\.originalFilename), ["a", "c", "b"])
    }

    func test_selectionIsCapped() {
        let vm = makeVM()
        let ids = (0..<40).map { "p\($0)" }
        vm.seedRecents(ids.map(rp))
        vm.didLongPressRecent(id: ids[0])
        for id in ids.dropFirst() { vm.didToggleMultiSelect(id: id) }

        XCTAssertEqual(vm.selectedRecentIDs.count, AttachmentPickerViewModel.selectionLimit)
        XCTAssertNotNil(vm.transientError, "hitting the cap must say so rather than ignoring taps")
    }

    /// Photos that fail to load were dropped in silence: pick five, three
    /// arrive, nothing said so.
    func test_partialLoadFailureIsReported() async {
        let vm = AttachmentPickerViewModel(photos: StubPhotosSource(failing: ["b"]))
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a"), rp("b"), rp("c")])
        vm.didLongPressRecent(id: "a")
        vm.didToggleMultiSelect(id: "b")
        vm.didToggleMultiSelect(id: "c")
        await vm.didConfirmRecentSelection()

        guard case .photoLibrary(let items) = emitted.first else { return XCTFail("no intent") }
        XCTAssertEqual(items.map(\.originalFilename), ["a", "c"], "the survivors still send, in order")
        XCTAssertNotNil(vm.transientError)
    }

    /// If every photo fails the sheet used to close as though it had sent them.
    func test_totalLoadFailureEmitsNothingAndReports() async {
        let vm = AttachmentPickerViewModel(photos: StubPhotosSource(failing: ["a", "b"]))
        var emitted: [AttachmentIntent] = []
        vm.onIntent = { emitted.append($0) }

        vm.seedRecents([rp("a"), rp("b")])
        vm.didLongPressRecent(id: "a")
        vm.didToggleMultiSelect(id: "b")
        await vm.didConfirmRecentSelection()

        XCTAssertTrue(emitted.isEmpty)
        XCTAssertNotNil(vm.transientError)
    }

    // MARK: helpers
    private func rp(_ id: String) -> RecentPhoto {
        RecentPhoto(id: id, kind: .photo, creationDate: nil, width: 100, height: 100, durationSeconds: nil)
    }
    private func makeVM() -> AttachmentPickerViewModel {
        AttachmentPickerViewModel(photos: StubPhotosSource())
    }
}

@MainActor
private final class StubPhotosSource: PhotosSourceProviding {
    /// Asset ids that fail to load, for exercising the partial-failure path.
    private let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    func currentPermission() -> PhotoPermission { .authorized }
    func requestPermission() async -> PhotoPermission { .authorized }
    func fetchRecents() -> [RecentPhoto] { [] }
    func loadPickedMedia(assetID: String) async -> PickedMedia? {
        guard !failing.contains(assetID) else { return nil }
        // `originalFilename` carries the asset id so tests can assert order.
        return PickedMedia(id: UUID(), kind: .photo, data: Data([0xAA]), fileURL: nil,
                           originalFilename: assetID, mimeType: "image/jpeg",
                           width: 1, height: 1, durationSeconds: nil)
    }
}
