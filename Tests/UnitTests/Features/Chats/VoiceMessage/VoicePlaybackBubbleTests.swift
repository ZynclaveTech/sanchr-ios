import Foundation
import XCTest

@testable import Sanchr

/// The voice note as it appears in a message bubble.
final class VoicePlaybackBubbleTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var bubble: String {
        get throws { try source("Features/Chats/Presentation/VoiceMessage/VoicePlaybackBubble.swift") }
    }

    /// Audio takes `.standard` chrome, so the message bubble already draws a
    /// background, a corner radius and padding. Drawing them again put a
    /// second rounded box inside the first — a grey slab on the outgoing
    /// gradient.
    func testTheBubbleDoesNotDrawASecondBubble() throws {
        let body = code(try bubble)
        XCTAssertFalse(body.contains("SanchrExportColors.surface"))
        XCTAssertFalse(body.contains("RoundedRectangle(cornerRadius: 18"))
    }

    /// Scrubbing divided by `translation.width + startLocation.x`, which is
    /// the definition of `location.x`, so every scrub jumped to the end. The
    /// same bug was fixed in the recording preview and missed here.
    func testScrubbingUsesTheStripWidth() throws {
        let body = code(try bubble)
        XCTAssertFalse(body.contains("g.translation.width + g.startLocation.x"))
        XCTAssertTrue(body.contains("proxy.size.width"))
    }

    /// A `GeometryReader` reports no ideal width, so the row collapsed around
    /// it: the waveform became a sliver and the clock wrapped onto two lines.
    func testTheWaveformClaimsAWidth() throws {
        XCTAssertTrue(try code(bubble).contains("minWidth: Self.minimumStripWidth"))
    }

    /// Nothing transmits the waveform, so every voice note from someone else
    /// arrives without one and the bubble drew an empty gap.
    func testAMissingWaveformIsDecodedLocally() throws {
        XCTAssertTrue(
            try code(bubble).contains("VoiceWaveformCache.shared.waveform(for: playableURL)"),
            "decode it from the audio rather than adding a field to the wire format"
        )
    }

    /// Pausing kept the message current — that is what preserves the position
    /// — so asking only "is this the current message" showed a pause button on
    /// a paused clip.
    func testPausedIsDistinguishedFromPlaying() throws {
        XCTAssertTrue(try code(bubble).contains("playback.isPlaying"))
    }

    func testDurationIsSpokenAsADuration() {
        XCTAssertEqual(VoicePlaybackBubble.spokenDuration(14), "14 seconds")
        XCTAssertEqual(VoicePlaybackBubble.spokenDuration(65), "1 minute, 5 seconds")
    }
}
