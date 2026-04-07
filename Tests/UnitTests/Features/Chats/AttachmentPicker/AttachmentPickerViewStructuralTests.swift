import XCTest
import UIKit
@testable import Sanchr

@MainActor
final class AttachmentPickerViewStructuralTests: XCTestCase {

    // MARK: - Action Pills

    func testActionPillsContainsFiveItemsInExpectedOrder() throws {
        let pills = AttachmentPickerActionPills()
        pills.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        pills.layoutIfNeeded()

        let buttons = collectPills(in: pills)
        XCTAssertEqual(buttons.count, 5, "Expected 5 action pills")

        let identifiers = buttons.map { $0.accessibilityIdentifier ?? "" }
        XCTAssertEqual(identifiers, [
            "attachmentPicker.actionPill.photos",
            "attachmentPicker.actionPill.gif",
            "attachmentPicker.actionPill.file",
            "attachmentPicker.actionPill.contact",
            "attachmentPicker.actionPill.location"
        ])
    }

    func testPhotosPillExists() throws {
        let pills = AttachmentPickerActionPills()
        pills.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        pills.layoutIfNeeded()

        let buttons = collectPills(in: pills)
        XCTAssertNotNil(buttons.first { $0.item == .photos })
    }

    // MARK: - Recents Strip

    func testRecentsStripContainsOnlyPhotoCells() throws {
        let strip = AttachmentPickerRecentsStrip(photosSource: PhotosLibrarySource())
        strip.frame = CGRect(x: 0, y: 0, width: 320, height: 96)
        strip.update(recents: [], selected: [], multiSelecting: false)
        strip.layoutIfNeeded()

        let cv = try XCTUnwrap(firstSubview(of: UICollectionView.self, in: strip))
        XCTAssertEqual(cv.accessibilityIdentifier, "attachmentPicker.recentsStrip")

        // Empty recents → 0 items, no camera tile registered.
        XCTAssertEqual(cv.numberOfItems(inSection: 0), 0)
    }

    // MARK: - Helpers

    private func collectPills(in view: UIView) -> [AttachmentPillButton] {
        var out: [AttachmentPillButton] = []
        for sv in view.subviews {
            if let pill = sv as? AttachmentPillButton {
                out.append(pill)
            } else {
                out.append(contentsOf: collectPills(in: sv))
            }
        }
        return out
    }

    private func firstSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        for sv in view.subviews {
            if let hit = sv as? T { return hit }
            if let nested = firstSubview(of: type, in: sv) { return nested }
        }
        return nil
    }
}

@MainActor
private final class StubPhotosSource: PhotosSourceProviding {
    func currentPermission() -> PhotoPermission { .authorized }
    func requestPermission() async -> PhotoPermission { .authorized }
    func fetchRecents() -> [RecentPhoto] { [] }
    func loadPickedMedia(assetID: String) async -> PickedMedia? { nil }
}
