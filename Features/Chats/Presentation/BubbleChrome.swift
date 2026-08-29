import CoreGraphics
import Foundation
import SanchrShared

/// How much bubble a message draws behind its content.
///
/// A photo already has a shape: it is a rounded rectangle of known size, and it
/// fills that shape edge to edge. Putting a padded, shadowed, stroked bubble
/// behind it draws a second rounded rectangle a few points larger than the
/// first, in a colour nobody sees except as a rim. Signal and WhatsApp both
/// drop it, and the media reads as the message.
///
/// Text is the opposite: it has no shape of its own, and the bubble is what
/// separates one person's words from the next.
enum BubbleChrome: Equatable {
    /// Content draws its own shape. No background, padding, shadow or border.
    case none
    /// Media with a caption. The bubble comes back — the caption needs it —
    /// but the media stays flush to the edges instead of floating inside a
    /// margin, so the two read as one object.
    case media
    /// Everything else.
    case standard

    var drawsBackground: Bool { self != .none }

    /// Whether the container pads its content. Media supplies its own padding
    /// where it needs it, which is around the caption and nowhere else.
    var padsContent: Bool { self == .standard }
}

enum BubbleChromePolicy {

    /// The most emoji a message can hold and still be drawn large and bare.
    ///
    /// Three is where both Signal and WhatsApp draw the line. Past it the
    /// glyphs stop reading as a gesture and start reading as text, and text
    /// wants a bubble.
    static let jumboEmojiLimit = 3

    static func chrome(for content: Message.MessageContent) -> BubbleChrome {
        switch content {
        case .text(let text):
            return jumboEmoji(in: text) != nil ? .none : .standard

        case .image(let media), .video(let media):
            // View-once is a placeholder tile, not the media — there is
            // nothing on screen for the bubble to be redundant with.
            if media.first?.isViewOnce == true { return .standard }
            return hasCaption(media) ? .media : .none

        case .audio, .document, .location, .contact, .system:
            // A voice note is a control strip, a document is a row of
            // metadata, and both are shapeless without the bubble.
            return .standard
        }
    }

    /// The emoji to draw large, or nil if this message is not eligible.
    ///
    /// Whitespace is ignored when judging, so "👍 👍" qualifies, but the
    /// original text is what gets returned and drawn.
    static func jumboEmoji(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let glyphs = trimmed.filter { !$0.isWhitespace }
        guard !glyphs.isEmpty,
              glyphs.count <= jumboEmojiLimit,
              glyphs.allSatisfy(\.isEmojiGlyph)
        else {
            return nil
        }
        return trimmed
    }

    /// Point size for a jumbo emoji message. Fewer glyphs, bigger glyphs — one
    /// emoji on its own is the whole message and should land like one.
    static func jumboEmojiSize(for text: String) -> CGFloat {
        switch text.filter({ !$0.isWhitespace }).count {
        case 1: return 56
        case 2: return 48
        default: return 40
        }
    }

    /// Narrowest a captioned bubble is allowed to be.
    ///
    /// Below this a caption wraps into a column too narrow to read. Media this
    /// narrow is already an extreme aspect ratio clamped to `minSide`, so the
    /// rim this leaves beside it is the lesser of the two problems.
    static let minimumCaptionedBubbleWidth: CGFloat = 150

    /// Width a caption gets beside media that renders `mediaWidth` wide.
    ///
    /// It plus its own inset has to come to the bubble's width, and the
    /// bubble's width has to be the media's — otherwise the bubble is wider
    /// than the photo and the photo stops being flush with the edge it is meant
    /// to meet, which is the whole point of keeping the bubble for captions but
    /// not for the media.
    ///
    /// The mistake worth naming: media is *not* always `maxWidth`.
    /// `displaySize` fits each attachment inside a 220x280 box, so anything
    /// portrait comes out narrower — a 9:16 clip lands near 157. Sizing
    /// captions to `maxWidth` therefore left an empty rim down the side of
    /// every portrait photo, which is exactly how this was spotted.
    static func captionWidth(forMediaWidth mediaWidth: CGFloat) -> CGFloat {
        max(mediaWidth, minimumCaptionedBubbleWidth) - SanchrSpacing.bubbleHPadding * 2
    }

    private static func hasCaption(_ media: Message.MediaAttachments) -> Bool {
        guard let caption = media.caption else { return false }
        return !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension Character {
    /// Whether this grapheme is an emoji rather than ordinary text.
    ///
    /// `isEmoji` alone is not enough: the digits and `#` and `*` carry it too,
    /// because they can be the base of a keycap sequence. A bare "1" is not an
    /// emoji, so a scalar in that range only counts when it is part of a longer
    /// cluster — which is exactly what a keycap is.
    var isEmojiGlyph: Bool {
        guard let first = unicodeScalars.first else { return false }
        guard first.properties.isEmoji else { return false }
        return first.value > 0x238C || unicodeScalars.count > 1
    }
}
