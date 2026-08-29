import SwiftUI
import SanchrShared

/// A message carrying several attachments, drawn as a collage.
///
/// Each tile is a `MediaBubbleImage` at a grid-supplied size, so the whole
/// download, decrypt, cache, auto-download-policy and tap-to-retry pipeline is
/// shared with the single-image bubble rather than reimplemented — a second
/// copy would drift, and the policy in particular is the sort of thing that
/// must not apply to some bubbles and not others.
struct MediaAlbumBubble: View {
    let attachments: Message.MediaAttachments
    let messageId: String
    let conversationId: String
    let isOutgoing: Bool
    /// Index into the album, so the viewer opens on the tile that was tapped.
    let onTapTile: (Int) -> Void

    private var width: CGFloat { BubbleMediaLayout.maxWidth }

    var body: some View {
        let layout = AlbumBubbleLayout.layout(count: attachments.count, width: width)

        ZStack(alignment: .topLeading) {
            ForEach(layout.tiles, id: \.index) { tile in
                if let attachment = attachment(at: tile.index) {
                    MediaBubbleImage(
                        attachment: attachment,
                        // Each tile caches under its own key; sharing the
                        // message id would make every tile collide on one
                        // cache entry and render the same photo.
                        messageId: "\(messageId)#\(tile.index)",
                        conversationId: conversationId,
                        isOutgoing: isOutgoing,
                        fixedSize: tile.rect.size,
                        // Square: the collage rounds its own outer corners, and
                        // a tile rounding all four of its own made an album read
                        // as four separate photos rather than one.
                        cornerRadius: 0
                    )
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .clipped()
                    .overlay {
                        if let hidden = tile.hiddenCount {
                            overflowBadge(hidden)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onTapTile(tile.index) }
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
                    .accessibilityLabel(accessibilityLabel(for: tile))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        .frame(width: width, height: layout.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func attachment(at index: Int) -> Message.MediaAttachment? {
        attachments.items.indices.contains(index) ? attachments.items[index] : nil
    }

    /// Covers the last tile when the album holds more than the grid shows.
    /// Tapping it still opens that tile, and the viewer pages on to the rest.
    private func overflowBadge(_ hidden: Int) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            Text("+\(hidden)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
    }

    private func accessibilityLabel(for tile: AlbumBubbleLayout.Tile) -> String {
        if let hidden = tile.hiddenCount {
            return "Photo \(tile.index + 1) of \(attachments.count), \(hidden) more"
        }
        return "Photo \(tile.index + 1) of \(attachments.count)"
    }
}
