import XCTest
import UIKit
@testable import Sanchr

@MainActor
final class AttachmentPickerViewStructuralTests: XCTestCase {

    // MARK: - Action Grid

    func testActionGridContainsFourTilesInExpectedOrder() throws {
        let grid = AttachmentPickerActionGrid()
        grid.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        grid.layoutIfNeeded()

        let tiles = collectTiles(in: grid)
        XCTAssertEqual(tiles.count, 4, "Expected 4 action grid tiles")

        let identifiers = tiles.map { $0.accessibilityIdentifier ?? "" }
        XCTAssertEqual(identifiers, [
            "attachmentPicker.actionGrid.vault",
            "attachmentPicker.actionGrid.file",
            "attachmentPicker.actionGrid.contact",
            "attachmentPicker.actionGrid.location"
        ])
    }

    func testVaultTileHasPurpleAccentBackground() throws {
        let grid = AttachmentPickerActionGrid()
        grid.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        grid.layoutIfNeeded()

        let tiles = collectTiles(in: grid)
        let vault = try XCTUnwrap(tiles.first { $0.item == .vault })
        let file = try XCTUnwrap(tiles.first { $0.item == .file })

        let vaultBG = try XCTUnwrap(vault.backgroundColor)
        let fileBG = try XCTUnwrap(file.backgroundColor)

        XCTAssertNotEqual(vaultBG, fileBG, "Vault tile should be visually differentiated from File tile")
    }

    // MARK: - Recents Strip

    func testRecentsStripFirstItemIsCameraTile() throws {
        let strip = AttachmentPickerRecentsStrip(photosSource: PhotosLibrarySource())
        strip.frame = CGRect(x: 0, y: 0, width: 320, height: 94)
        strip.update(recents: [], selected: [], multiSelecting: false)
        strip.layoutIfNeeded()

        let cv = try XCTUnwrap(firstSubview(of: UICollectionView.self, in: strip))
        XCTAssertEqual(cv.accessibilityIdentifier, "attachmentPicker.recentsStrip")

        let cell = cv.dataSource?.collectionView(cv, cellForItemAt: IndexPath(item: 0, section: 0))
        let unwrapped = try XCTUnwrap(cell)
        XCTAssertTrue(unwrapped is CameraTileCell, "First item should be CameraTileCell, got \(type(of: unwrapped))")
        XCTAssertEqual(unwrapped.accessibilityIdentifier, "attachmentPicker.cameraTile")
        XCTAssertEqual(unwrapped.accessibilityLabel, "Camera")
    }

    // MARK: - Header A11y

    func testE2EEChipIsAccessible() throws {
        let view = makePickerView()
        let chip = try XCTUnwrap(findSubview(in: view, identifier: "attachmentPicker.header.e2eeChip"))
        XCTAssertTrue(chip.isAccessibilityElement)
        let label = try XCTUnwrap(chip.accessibilityLabel)
        XCTAssertNotNil(label.range(of: "encrypted", options: .caseInsensitive),
                        "Expected accessibilityLabel to mention 'encrypted', got: \(label)")
    }

    func testAllPhotosHeaderLinkIsAccessible() throws {
        let view = makePickerView()
        let link = try XCTUnwrap(findSubview(in: view, identifier: "attachmentPicker.header.allPhotos"))
        XCTAssertTrue(link.isAccessibilityElement)
        let label = try XCTUnwrap(link.accessibilityLabel)
        XCTAssertNotNil(label.range(of: "photos", options: .caseInsensitive),
                        "Expected accessibilityLabel to mention 'photos', got: \(label)")
    }

    // MARK: - Helpers

    private func makePickerView() -> AttachmentPickerView {
        let vm = AttachmentPickerViewModel(photos: StubPhotosSource())
        let view = AttachmentPickerView(viewModel: vm, photosSource: PhotosLibrarySource())
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 320)
        view.layoutIfNeeded()
        return view
    }

    private func collectTiles(in view: UIView) -> [AttachmentGridTile] {
        var out: [AttachmentGridTile] = []
        for sv in view.subviews {
            if let tile = sv as? AttachmentGridTile {
                out.append(tile)
            } else {
                out.append(contentsOf: collectTiles(in: sv))
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

    private func findSubview(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for sv in view.subviews {
            if let hit = findSubview(in: sv, identifier: identifier) { return hit }
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
