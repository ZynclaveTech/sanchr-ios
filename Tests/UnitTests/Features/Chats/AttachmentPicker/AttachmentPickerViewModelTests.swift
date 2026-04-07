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
    func currentPermission() -> PhotoPermission { .authorized }
    func requestPermission() async -> PhotoPermission { .authorized }
    func fetchRecents() -> [RecentPhoto] { [] }
    func loadPickedMedia(assetID: String) async -> PickedMedia? {
        PickedMedia(id: UUID(), kind: .photo, data: Data([0xAA]), fileURL: nil,
                    originalFilename: assetID, mimeType: "image/jpeg",
                    width: 1, height: 1, durationSeconds: nil)
    }
}
