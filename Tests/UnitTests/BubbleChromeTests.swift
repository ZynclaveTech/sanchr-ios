import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Which messages draw a bubble behind their content.
final class BubbleChromeTests: XCTestCase {

    private func media(
        mime: String = "image/jpeg",
        caption: String? = nil,
        viewOnce: Bool? = nil,
        count: Int = 1
    ) -> Message.MediaAttachments {
        let items = (0..<count).map { index -> Message.MediaAttachment in
            var a = Message.MediaAttachment(
                url: URL(string: "sanchr-media://m\(index)")!,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mime,
                sizeBytes: 1,
                thumbnailURL: nil
            )
            if index == 0 { a.caption = caption }
            a.isViewOnce = viewOnce
            return a
        }
        return Message.MediaAttachments(items)
    }

    // MARK: - Media

    /// The ask. A photo is already a rounded rectangle at a known size; the
    /// bubble behind it only ever showed as a rim.
    func testBareMediaDrawsNoBubble() {
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .image(media())), .none)
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .video(media(mime: "video/mp4"))), .none)
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .image(media(mime: "image/gif"))), .none)
    }

    func testAnAlbumDrawsNoBubble() {
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .image(media(count: 4))), .none)
    }

    /// With a caption the bubble comes back, because the caption needs it —
    /// but the media stays flush, so the container must not pad.
    func testCaptionedMediaKeepsTheBubbleWithoutPaddingTheMedia() {
        let chrome = BubbleChromePolicy.chrome(for: .image(media(caption: "at the beach")))
        XCTAssertEqual(chrome, .media)
        XCTAssertTrue(chrome.drawsBackground)
        XCTAssertFalse(chrome.padsContent, "media must sit flush to the bubble edges")
    }

    /// A caption of only spaces is not a caption. Treating it as one would put
    /// an empty bubble rim around the photo and a blank line under it.
    func testBlankCaptionIsNotACaption() {
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .image(media(caption: "   "))), .none)
    }

    /// View-once shows a placeholder tile, not the media. There is nothing on
    /// screen for the bubble to be redundant with.
    func testViewOnceKeepsItsBubble() {
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .image(media(viewOnce: true))), .standard)
    }

    // MARK: - Shapeless content

    func testTextAndControlsKeepTheirBubble() {
        let cases: [Message.MessageContent] = [
            .text("hello"),
            .audio(media(mime: "audio/mp4")),
            .document(media(mime: "application/pdf")),
            .location(latitude: 1, longitude: 2),
            .contact(name: "A", phoneNumber: "+1"),
        ]
        for content in cases {
            XCTAssertEqual(
                BubbleChromePolicy.chrome(for: content), .standard,
                "\(content) has no shape of its own and needs the bubble"
            )
        }
    }

    // MARK: - Jumbo emoji

    func testShortEmojiMessagesGoBare() {
        for text in ["👍", "😂😂", "🎉🎉🎉", "👍 👍"] {
            XCTAssertEqual(
                BubbleChromePolicy.chrome(for: .text(text)), .none,
                "\(text) should be drawn large and bare"
            )
        }
    }

    /// Past three, emoji read as text and text wants a bubble.
    func testTooManyEmojiKeepTheBubble() {
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .text("😀😀😀😀")), .standard)
    }

    func testEmojiMixedWithTextKeepsTheBubble() {
        for text in ["ok 👍", "👍!", "1"] {
            XCTAssertEqual(
                BubbleChromePolicy.chrome(for: .text(text)), .standard,
                "\(text) is not emoji-only"
            )
        }
    }

    /// The heuristic's sharp edge: digits and `#`/`*` report `isEmoji` because
    /// they can begin a keycap sequence. A bare digit is not an emoji; the
    /// keycap built from it is.
    func testDigitsAreNotEmojiButKeycapsAre() {
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .text("123")), .standard)
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .text("1️⃣")), .none)
    }

    /// Multi-scalar emoji are one grapheme and must count as one, or a family
    /// or a skin-toned thumb would blow the limit on its own.
    func testCompoundEmojiCountAsOne() {
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .text("👨‍👩‍👧‍👦")), .none)
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .text("👍🏽")), .none)
        XCTAssertEqual(BubbleChromePolicy.chrome(for: .text("🏳️‍🌈🏳️‍🌈🏳️‍🌈")), .none)
    }

    func testEmptyAndWhitespaceAreNotJumbo() {
        XCTAssertNil(BubbleChromePolicy.jumboEmoji(in: ""))
        XCTAssertNil(BubbleChromePolicy.jumboEmoji(in: "   \n "))
    }

    /// Surrounding whitespace is ignored when judging but the text that gets
    /// drawn is the trimmed original, not a reconstruction.
    func testJumboReturnsTheTrimmedOriginal() {
        XCTAssertEqual(BubbleChromePolicy.jumboEmoji(in: "  🎉  "), "🎉")
        XCTAssertEqual(BubbleChromePolicy.jumboEmoji(in: "👍 👍"), "👍 👍")
    }

    /// Fewer glyphs, bigger glyphs — and never larger for more of them.
    func testJumboSizeShrinksAsGlyphsAreAdded() {
        let sizes = ["👍", "👍👍", "👍👍👍"].map(BubbleChromePolicy.jumboEmojiSize(for:))
        XCTAssertEqual(sizes, sizes.sorted(by: >), "size must not grow with glyph count")
        XCTAssertEqual(Set(sizes).count, 3, "each count should have its own size")
    }

    /// Whitespace must not change the size, or "👍 👍" would be drawn at the
    /// three-glyph size.
    func testJumboSizeIgnoresWhitespace() {
        XCTAssertEqual(
            BubbleChromePolicy.jumboEmojiSize(for: "👍 👍"),
            BubbleChromePolicy.jumboEmojiSize(for: "👍👍")
        )
    }

    // MARK: - Caption geometry

    /// A caption plus its inset must come to the media's own width, so the
    /// bubble is exactly as wide as the photo and the photo stays flush.
    func testCaptionAndItsInsetMatchTheMediaWidth() {
        for mediaWidth in [BubbleMediaLayout.maxWidth, 210, 180, 157] as [CGFloat] {
            XCTAssertEqual(
                BubbleChromePolicy.captionWidth(forMediaWidth: mediaWidth)
                    + SanchrSpacing.bubbleHPadding * 2,
                mediaWidth,
                accuracy: 0.001,
                "a bubble beside \(mediaWidth)pt media must be \(mediaWidth)pt wide"
            )
        }
    }

    /// The bug this replaced. Media is not always `maxWidth` — `displaySize`
    /// fits each attachment inside a 220x280 box, so anything portrait comes
    /// out narrower. Sizing captions to `maxWidth` left an empty rim down the
    /// side of every portrait photo.
    func testPortraitMediaDoesNotGetAWiderBubbleThanItself() {
        var portrait = Message.MediaAttachment(
            url: URL(string: "sanchr-media://p")!,
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: "video/mp4", sizeBytes: 1, thumbnailURL: nil
        )
        portrait.width = 1080
        portrait.height = 1920

        let rendered = BubbleMediaLayout.displaySize(for: portrait).width
        XCTAssertLessThan(rendered, BubbleMediaLayout.maxWidth, "precondition: portrait is narrower")
        XCTAssertEqual(
            BubbleChromePolicy.captionWidth(forMediaWidth: rendered)
                + SanchrSpacing.bubbleHPadding * 2,
            rendered,
            accuracy: 0.001
        )
    }

    /// Media clamped to `minSide` is a sliver. A caption still has to be
    /// readable, so the floor wins there and the rim is accepted.
    func testAVeryNarrowMediaStillGetsAReadableCaption() {
        let width = BubbleChromePolicy.captionWidth(forMediaWidth: BubbleMediaLayout.minSide)
        XCTAssertGreaterThan(width, 100, "a caption this narrow could not be read")
        XCTAssertEqual(
            width + SanchrSpacing.bubbleHPadding * 2,
            BubbleChromePolicy.minimumCaptionedBubbleWidth,
            accuracy: 0.001
        )
    }
}
