import Foundation
import XCTest

@testable import Sanchr

/// The attachment tray: what it says when it has nothing, what it says when
/// something fails, and whether a selection can be completed at all.
@MainActor
final class AttachmentTrayTests: XCTestCase {

    // MARK: - Fakes

    private final class FakePhotos: PhotosSourceProviding {
        var permission: PhotoPermission = .authorized
        var recents: [RecentPhoto] = []
        var loadable = true

        func currentPermission() -> PhotoPermission { permission }
        func requestPermission() async -> PhotoPermission { permission }
        func fetchRecents() -> [RecentPhoto] { recents }
        func loadPickedMedia(assetID: String) async -> PickedMedia? {
            guard loadable else { return nil }
            return PickedMedia(
                id: UUID(),
                kind: .photo,
                data: Data(),
                fileURL: nil,
                originalFilename: "\(assetID).jpg",
                mimeType: "image/jpeg",
                width: 100,
                height: 100,
                durationSeconds: nil
            )
        }
    }

    private func photo(_ id: String) -> RecentPhoto {
        RecentPhoto(id: id, kind: .photo, creationDate: nil, width: 100, height: 100, durationSeconds: nil)
    }

    // MARK: - Empty states

    /// A refused library and an empty one both rendered as blank space, so a
    /// decision you had made looked identical to a phone with no photos.
    func testARefusedLibrarySaysSo() async {
        let photos = FakePhotos()
        photos.permission = .denied
        let sut = AttachmentPickerViewModel(photos: photos)
        await sut.reloadRecents()
        XCTAssertEqual(sut.emptyReason, .denied)
    }

    func testAnEmptyLibrarySaysSomethingElse() async {
        let photos = FakePhotos()
        let sut = AttachmentPickerViewModel(photos: photos)
        await sut.reloadRecents()
        XCTAssertEqual(sut.emptyReason, .noPhotos)
    }

    func testAPopulatedLibraryHasNoEmptyState() async {
        let photos = FakePhotos()
        photos.recents = [photo("a"), photo("b")]
        let sut = AttachmentPickerViewModel(photos: photos)
        await sut.reloadRecents()
        XCTAssertNil(sut.emptyReason)
    }

    // MARK: - Selection

    /// Selecting several photos could be started and never finished: the
    /// confirm and cancel methods were called from nowhere at all.
    func testAMultipleSelectionCanBeConfirmed() async {
        let photos = FakePhotos()
        photos.recents = [photo("a"), photo("b")]
        let sut = AttachmentPickerViewModel(photos: photos)
        await sut.reloadRecents()

        var sent: [PickedMedia] = []
        sut.onIntent = { intent in
            if case .photoLibrary(let items) = intent { sent = items }
        }

        sut.didLongPressRecent(id: "a")
        sut.didToggleMultiSelect(id: "b")
        await sut.didConfirmRecentSelection()

        XCTAssertEqual(sent.count, 2)
        XCTAssertFalse(sut.isMultiSelecting, "confirming ends the selection")
    }

    func testAMultipleSelectionCanBeAbandoned() {
        let sut = AttachmentPickerViewModel(photos: FakePhotos())
        sut.didLongPressRecent(id: "a")
        XCTAssertTrue(sut.isMultiSelecting)

        sut.didCancelMultiSelect()

        XCTAssertFalse(sut.isMultiSelecting)
        XCTAssertTrue(sut.selectedRecentIDs.isEmpty)
    }

    /// Going over the ceiling produced a message that nothing displayed, so
    /// the tap simply appeared to do nothing.
    func testTheSelectionLimitExplainsItself() {
        let sut = AttachmentPickerViewModel(photos: FakePhotos())
        sut.didLongPressRecent(id: "0")
        for i in 1..<AttachmentPickerViewModel.selectionLimit {
            sut.didToggleMultiSelect(id: "\(i)")
        }
        XCTAssertEqual(sut.selectedRecentIDs.count, AttachmentPickerViewModel.selectionLimit)

        sut.didToggleMultiSelect(id: "over")

        XCTAssertEqual(sut.selectedRecentIDs.count, AttachmentPickerViewModel.selectionLimit)
        XCTAssertNotNil(sut.transientError, "refusing silently is the bug")
    }

    /// A photo that fails to load was dropped without a word.
    func testAFailedLoadIsReported() async {
        let photos = FakePhotos()
        photos.loadable = false
        let sut = AttachmentPickerViewModel(photos: photos)
        await sut.didTapRecentPhoto(id: "a")
        XCTAssertNotNil(sut.transientError)
    }

    // MARK: - Location

    /// Location failures were logged and nothing else, so a refusal made the
    /// pill look inert.
    func testLocationRefusalIsDistinguishedFromOtherFailures() {
        let denied = ChatDetailView.locationFailureMessage(LocationSource.Error.denied)
        let timeout = ChatDetailView.locationFailureMessage(LocationSource.Error.timeout)
        XCTAssertTrue(denied.contains("Settings"), "a refusal is fixable, and should say where")
        XCTAssertNotEqual(denied, timeout)
    }

    func testAnUnknownLocationFailureStillSaysSomething() {
        let message = ChatDetailView.locationFailureMessage(
            NSError(domain: "x", code: 1)
        )
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Accessibility

    /// Every cell used to be "Recent photo", identically, so VoiceOver could
    /// not tell one from the next.
    func testEachPhotoIsDescribedDistinctly() {
        let first = AttachmentPickerRecentsStrip.accessibilityLabel(
            for: photo("a"), position: 1, of: 40
        )
        let second = AttachmentPickerRecentsStrip.accessibilityLabel(
            for: photo("b"), position: 2, of: 40
        )
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains("1 of 40"))
    }

    func testAVideoSaysItIsAVideoAndHowLong() {
        let video = RecentPhoto(
            id: "v", kind: .video, creationDate: nil,
            width: 100, height: 100, durationSeconds: 65
        )
        let label = AttachmentPickerRecentsStrip.accessibilityLabel(for: video, position: 3, of: 9)
        XCTAssertTrue(label.hasPrefix("Video"))
        XCTAssertTrue(label.contains("1 minute, 5 seconds"))
    }

    // MARK: - Wiring
    //
    // The view model could always confirm a selection and always set an error
    // string. What was missing was anything calling or reading them, so these
    // assert the wiring rather than the methods.

    private func pickerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Features/Chats/Presentation/AttachmentPicker/AttachmentPickerView.swift"
            ),
            encoding: .utf8
        )
    }

    private func stripped(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Long-press began a selection and numbered every tap after it, and there
    /// was nothing to press to send them.
    func testTheSelectionCanBeCompletedFromTheUI() throws {
        let body = stripped(try pickerSource())
        XCTAssertTrue(body.contains("viewModel.didConfirmRecentSelection()"))
        XCTAssertTrue(body.contains("viewModel.didCancelMultiSelect()"))
    }

    /// Four different messages were written into `transientError` and nothing
    /// ever read it.
    func testErrorsReachTheScreen() throws {
        let body = stripped(try pickerSource())
        XCTAssertTrue(
            body.contains("viewModel.$transientError"),
            "the error has to be observed somewhere, not only written"
        )
    }

    /// A refusal is only actionable if there is a route to Settings, which is
    /// the sole way back once iOS has recorded the decision.
    func testARefusalOffersAWayBack() throws {
        let body = stripped(try pickerSource())
        XCTAssertTrue(body.contains("UIApplication.openSettingsURLString"))
    }

    /// The empty message is positioned over the strip, so the strip has to
    /// keep its height when there is nothing in it.
    ///
    /// Hiding it collapsed it — it is an arranged subview of a stack view —
    /// and took the space the explanation was drawn in, so a refused library
    /// went back to showing nothing at all, which is the bug being fixed.
    func testTheStripKeepsItsSpaceWhileTheEmptyMessageShows() throws {
        let body = stripped(try pickerSource())
        XCTAssertTrue(
            body.contains("recentsStrip.alpha = reason == nil ? 1 : 0"),
            "fade the strip; hiding it collapses the stack and the message with it"
        )
        XCTAssertFalse(
            body.contains("recentsStrip.isHidden = reason != nil"),
            "isHidden on an arranged subview removes its height"
        )
    }
}
