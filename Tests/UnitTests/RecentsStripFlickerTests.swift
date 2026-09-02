import UIKit
import XCTest
@testable import Sanchr

/// Selecting a photo in the composer's recents strip used to reload the whole
/// strip, and every reloaded cell blanked its thumbnail and fetched it again:
/// the row flickered on each tap.
@MainActor
final class RecentsStripFlickerTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func photo(_ id: String) -> RecentPhoto {
        RecentPhoto(id: id, kind: .photo, creationDate: nil, width: 100, height: 100, durationSeconds: nil)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func thumbnail(in cell: UICollectionViewCell) -> UIImage? {
        cell.contentView.subviews.compactMap { $0 as? UIImageView }.first?.image
    }

    func testReconfiguringTheSamePhotoKeepsItsThumbnail() async {
        let cell = RecentPhotoCell(frame: CGRect(x: 0, y: 0, width: 112, height: 112))
        final class Counter { var loads = 0 }
        let counter = Counter()
        let loader: @MainActor @Sendable (CGSize) async -> UIImage? = { _ in
            counter.loads += 1
            return UIImage(systemName: "photo")
        }

        cell.configure(photo: photo("a"), selectionIndex: nil, multiSelecting: false, thumbnailLoader: loader)
        await settle()
        XCTAssertEqual(counter.loads, 1)
        XCTAssertNotNil(thumbnail(in: cell))

        // The selection tap: same photo, badge changes.
        cell.configure(photo: photo("a"), selectionIndex: 0, multiSelecting: true, thumbnailLoader: loader)
        XCTAssertNotNil(thumbnail(in: cell), "the thumbnail must never blank on a selection change")
        await settle()
        XCTAssertEqual(counter.loads, 1, "the same asset is not fetched again")

        // A different photo in a reused cell does load.
        cell.prepareForReuse()
        cell.configure(photo: photo("b"), selectionIndex: nil, multiSelecting: false, thumbnailLoader: loader)
        await settle()
        XCTAssertEqual(counter.loads, 2)
    }

    func testSelectionChangesDoNotReloadTheStrip() throws {
        let strip = try String(
            contentsOf: Self.root.appendingPathComponent("Features/Chats/Presentation/AttachmentPicker/AttachmentPickerRecentsStrip.swift"),
            encoding: .utf8
        )
        let update = try XCTUnwrap(strip.range(of: "func update(recents: [RecentPhoto], selected: [String], multiSelecting: Bool) {"))
        let body = String(strip[update.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("guard !recentsChanged else {"), "reload only when the photos themselves changed")
        XCTAssertTrue(body.contains("indexPathsForVisibleItems"), "selection updates touch visible cells in place")
        XCTAssertTrue(body.contains("cell.applySelection("))
    }
}
