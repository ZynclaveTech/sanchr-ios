import SwiftUI
import UIKit
import XCTest
import SanchrShared

@testable import Sanchr

/// Renders real `MessageBubble`s to PNGs so the jumbo-emoji treatment can be
/// looked at.
///
/// The policy behind it is unit-tested already, but nothing proved the view
/// actually draws what the policy decides — and this is a purely visual change,
/// the kind that passes every assertion and still looks wrong. The alternative
/// was sending an emoji to a real contact to see it in the transcript, which is
/// not a reasonable way to test a font size.
@MainActor
final class JumboEmojiRenderTests: XCTestCase {

    private static let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jumbo-emoji-render", isDirectory: true)

    private func bubble(_ text: String, outgoing: Bool = false) -> some View {
        MessageBubble(
            message: Message(
                id: "m-\(text.hashValue)",
                conversationId: "c",
                senderId: outgoing ? "me" : "them",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                content: .text(text),
                status: .read,
                isOutgoing: outgoing
            ),
            voicePlayback: VoicePlaybackController()
        )
        .padding(12)
        .background(Color(white: 0.95))
        .frame(width: 380)
    }

    /// Writes a PNG and returns its size, so a zero-height or collapsed render
    /// fails loudly rather than producing an image nobody looks at.
    @discardableResult
    private func render(_ view: some View, named name: String) throws -> CGSize {
        try FileManager.default.createDirectory(
            at: Self.outputDirectory,
            withIntermediateDirectories: true
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "\(name) rendered nothing")
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        return image.size
    }

    func testRenderJumboEmojiAndComparisons() throws {
        let cases: [(String, String)] = [
            ("01-single-emoji", "👍"),
            ("02-two-emoji", "😂😂"),
            ("03-three-emoji", "🎉🎉🎉"),
            ("04-four-emoji-should-be-a-normal-bubble", "😀😀😀😀"),
            ("05-emoji-with-text-should-be-a-normal-bubble", "nice 👍"),
            ("06-compound-emoji", "👨‍👩‍👧‍👦"),
            ("07-plain-text-for-comparison", "Hello there"),
        ]
        for (name, text) in cases {
            let size = try render(bubble(text), named: name)
            XCTAssertGreaterThan(size.height, 0, "\(name) collapsed to nothing")
        }
        try render(bubble("👍", outgoing: true), named: "08-single-emoji-outgoing")

        print("RENDERED_TO: \(Self.outputDirectory.path)")
    }

    /// The rendered heights encode the whole treatment, so asserting on them
    /// pins it end to end — through the real view rather than the policy alone.
    ///
    /// One emoji is drawn largest, and each one added shrinks it, until past
    /// three the message becomes an ordinary bubble at body size.
    func testHeightsShrinkWithEachEmojiAndStopAtFour() throws {
        let one = try render(bubble("👍"), named: "cmp-1").height
        let two = try render(bubble("👍👍"), named: "cmp-2").height
        let three = try render(bubble("👍👍👍"), named: "cmp-3").height
        let four = try render(bubble("👍👍👍👍"), named: "cmp-4").height
        let plain = try render(bubble("Hello there"), named: "cmp-plain").height

        XCTAssertGreaterThan(one, two, "one emoji should be drawn largest")
        XCTAssertGreaterThan(two, three, "two should be drawn larger than three")
        XCTAssertGreaterThan(three, four, "past three the treatment must stop")
        XCTAssertEqual(
            four, plain, accuracy: 1,
            "four emoji is an ordinary message and should be the height of one"
        )
    }

    /// The point of the treatment: a lone emoji must be visibly larger than the
    /// same emoji sitting inside a sentence.
    func testAJumboEmojiIsTallerThanTheSameEmojiInASentence() throws {
        let jumbo = try render(bubble("👍"), named: "cmp-jumbo")
        let inline = try render(bubble("nice 👍"), named: "cmp-inline")
        XCTAssertGreaterThan(
            jumbo.height, inline.height,
            "a lone emoji should be drawn large; it is no bigger than body text"
        )
    }
}
