import CoreGraphics
import XCTest

@testable import Sanchr

/// Tile geometry for the multi-image bubble. Pure maths, so the awkward cases
/// are worth pinning: the asymmetric three-up, the overflow badge, and an album
/// far larger than the grid shows.
final class AlbumBubbleLayoutTests: XCTestCase {

    private let width: CGFloat = 220

    private func layout(_ count: Int) -> AlbumBubbleLayout.Result {
        AlbumBubbleLayout.layout(count: count, width: width)
    }

    /// A lone attachment keeps the aspect-correct bubble; forcing it into a
    /// square would look worse than what it replaces.
    func testSingleAttachmentIsNotLaidOutAsAGrid() {
        XCTAssertTrue(layout(1).tiles.isEmpty)
        XCTAssertEqual(layout(1).height, 0)
    }

    func testTwoSitSideBySide() {
        let result = layout(2)
        XCTAssertEqual(result.tiles.count, 2)
        XCTAssertEqual(result.tiles[0].rect.minY, result.tiles[1].rect.minY, "same row")
        XCTAssertLessThan(result.tiles[0].rect.maxX, result.tiles[1].rect.minX, "no overlap")
    }

    func testThreeAreOneLargePlusAStackedPair() {
        let result = layout(3)
        XCTAssertEqual(result.tiles.count, 3)

        let large = result.tiles[0]
        XCTAssertEqual(large.rect.height, result.height, "the large tile spans the block")
        XCTAssertEqual(result.tiles[1].rect.minX, result.tiles[2].rect.minX, "stacked in one column")
        XCTAssertLessThan(result.tiles[1].rect.maxY, result.tiles[2].rect.minY, "no overlap")
    }

    func testFourAreASquareGrid() {
        let result = layout(4)
        XCTAssertEqual(result.tiles.count, 4)
        let sides = Set(result.tiles.map { "\($0.rect.width)x\($0.rect.height)" })
        XCTAssertEqual(sides.count, 1, "all four tiles are the same size")
    }

    // MARK: - Overflow

    /// The grid stops at four; the rest are counted on the last tile.
    func testBeyondFourShowsFourWithARemainderBadge() {
        let result = layout(9)
        XCTAssertEqual(result.tiles.count, AlbumBubbleLayout.maxVisibleTiles)
        XCTAssertEqual(result.tiles.last?.hiddenCount, 5, "9 shown as 4 with +5")
    }

    /// Exactly four hides nothing — an off-by-one here would render "+0".
    func testExactlyFourHasNoBadge() {
        XCTAssertNil(layout(4).tiles.last?.hiddenCount)
    }

    func testFiveShowsPlusOne() {
        XCTAssertEqual(layout(5).tiles.last?.hiddenCount, 1)
    }

    /// Only the last visible tile carries the badge.
    func testBadgeAppearsOnlyOnce() {
        let badged = layout(12).tiles.filter { $0.hiddenCount != nil }
        XCTAssertEqual(badged.count, 1)
        XCTAssertEqual(badged.first?.index, AlbumBubbleLayout.maxVisibleTiles - 1)
    }

    // MARK: - Invariants across every count

    func testTilesNeverExceedTheBubbleWidth() {
        for count in 2...20 {
            for tile in layout(count).tiles {
                XCTAssertLessThanOrEqual(
                    tile.rect.maxX, width + 0.5, "count \(count) overflows the bubble"
                )
                XCTAssertGreaterThan(tile.rect.width, 0, "count \(count) produced an empty tile")
                XCTAssertGreaterThan(tile.rect.height, 0, "count \(count) produced an empty tile")
            }
        }
    }

    func testTilesNeverExceedTheReportedHeight() {
        for count in 2...20 {
            let result = layout(count)
            for tile in result.tiles {
                XCTAssertLessThanOrEqual(
                    tile.rect.maxY, result.height + 0.5,
                    "count \(count) draws outside the block it reports"
                )
            }
        }
    }

    func testIndicesAreSequentialFromZero() {
        for count in 2...20 {
            let indices = layout(count).tiles.map(\.index)
            XCTAssertEqual(indices, Array(0..<indices.count), "count \(count)")
        }
    }

    /// Degenerate input must not produce NaN or negative geometry.
    func testZeroWidthIsHandled() {
        let result = AlbumBubbleLayout.layout(count: 4, width: 0)
        XCTAssertTrue(result.tiles.isEmpty)
        XCTAssertEqual(result.height, 0)
    }
}
