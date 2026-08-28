import CoreGraphics

/// Tile geometry for a multi-attachment bubble.
///
/// Kept as a pure function rather than expressed in the view so the awkward
/// cases — the asymmetric three-up, the overflow badge, an album larger than
/// the grid shows — can be tested without rendering anything.
///
/// The shapes follow the collage every messenger has converged on, because it
/// is the one people can read at a glance: two side by side, three as one
/// large plus a stacked pair, four as a square grid, and beyond four the same
/// grid with a "+N" on the last tile.
enum AlbumBubbleLayout {

    /// Beyond this the grid stops growing and the last tile carries the
    /// remainder. Four tiles is the most that stays legible at bubble width.
    static let maxVisibleTiles = 4

    static let spacing: CGFloat = 2

    struct Tile: Equatable {
        /// Index into the album's attachments.
        let index: Int
        let rect: CGRect
        /// Set on the last visible tile when the album holds more than it
        /// shows; the view draws a "+N" over it.
        let hiddenCount: Int?
    }

    struct Result: Equatable {
        let tiles: [Tile]
        let height: CGFloat
    }

    /// Lays out `count` attachments into `width`.
    ///
    /// A single attachment is not laid out here — it keeps the existing
    /// aspect-correct bubble, which looks better than forcing it into a square.
    static func layout(count: Int, width: CGFloat) -> Result {
        guard count > 1, width > 0 else { return Result(tiles: [], height: 0) }

        let gap = spacing
        let half = ((width - gap) / 2).rounded()
        let visible = min(count, maxVisibleTiles)
        let hidden = count - visible

        /// The remainder badge belongs on the last tile shown, and only when
        /// something is actually hidden.
        func hiddenCount(for index: Int) -> Int? {
            index == visible - 1 && hidden > 0 ? hidden : nil
        }

        switch visible {
        case 2:
            // Two squares side by side.
            let height = half
            return Result(
                tiles: [
                    Tile(index: 0, rect: CGRect(x: 0, y: 0, width: half, height: height),
                         hiddenCount: hiddenCount(for: 0)),
                    Tile(index: 1, rect: CGRect(x: half + gap, y: 0, width: half, height: height),
                         hiddenCount: hiddenCount(for: 1)),
                ],
                height: height
            )

        case 3:
            // One large on the left, two stacked on the right. The large tile
            // spans the full height so the block stays rectangular.
            // The quarter is rounded first and the block height derived from
            // it. Rounding the other way round let the stacked pair total one
            // point more than the height reported, so the lower tile drew
            // outside the bubble.
            let quarter = ((width * 0.75 - gap) / 2).rounded(.down)
            let height = quarter * 2 + gap
            return Result(
                tiles: [
                    Tile(index: 0, rect: CGRect(x: 0, y: 0, width: half, height: height),
                         hiddenCount: hiddenCount(for: 0)),
                    Tile(index: 1, rect: CGRect(x: half + gap, y: 0, width: half, height: quarter),
                         hiddenCount: hiddenCount(for: 1)),
                    Tile(index: 2, rect: CGRect(x: half + gap, y: quarter + gap, width: half, height: quarter),
                         hiddenCount: hiddenCount(for: 2)),
                ],
                height: height
            )

        default:
            // Four squares. Anything beyond four rides the last tile's badge.
            let height = half * 2 + gap
            return Result(
                tiles: (0..<4).map { index in
                    let row = CGFloat(index / 2)
                    let column = CGFloat(index % 2)
                    return Tile(
                        index: index,
                        rect: CGRect(
                            x: column * (half + gap),
                            y: row * (half + gap),
                            width: half,
                            height: half
                        ),
                        hiddenCount: hiddenCount(for: index)
                    )
                },
                height: height
            )
        }
    }
}
