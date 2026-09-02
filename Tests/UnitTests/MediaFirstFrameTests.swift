import Foundation
import XCTest

@testable import Sanchr

/// What a media bubble shows in its first frame when it comes back on screen.
///
/// A `.task` runs after the view has been drawn once, so consulting a cache
/// there means the first frame is always the empty state — the placeholder for
/// a photo, flat bars for a voice note — followed by a swap to something that
/// was in memory the whole time. Nothing is fetched twice; it only looks that
/// way, on every return to the transcript.
final class MediaFirstFrameTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
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

    func testAPhotoIsSeededFromTheCacheBeforeTheFirstFrame() throws {
        let body = code(try source("Features/Chats/Presentation/MediaBubbleImage.swift"))
        XCTAssertTrue(
            body.contains("_resolvedImage = State(") &&
            body.contains("Self.imageCache.object(forKey: messageId as NSString)"),
            "read the cache in init; a .task reads it a frame too late"
        )
    }

    func testAVoiceNoteIsSeededFromTheCacheBeforeTheFirstFrame() throws {
        let body = code(try source("Features/Chats/Presentation/VoiceMessage/VoicePlaybackBubble.swift"))
        XCTAssertTrue(body.contains("_decoded = State(initialValue: VoiceWaveformCache.cached(for: attachment.url)"))
    }

    /// An actor can only be read from an async context, which is the whole
    /// reason the lookup was late. The synchronous view is what makes seeding
    /// possible at all.
    func testTheWaveformCacheCanBeReadWithoutAwaiting() throws {
        let body = code(try source("Features/Chats/Presentation/VoiceMessage/VoiceWaveformCache.swift"))
        XCTAssertTrue(body.contains("nonisolated static func cached(for url: URL) -> [Float]?"))
    }

    /// Seeded and then decoded again would be the same wasted work, one frame
    /// later.
    func testASeededWaveformIsNotDecodedAgain() throws {
        let body = code(try source("Features/Chats/Presentation/VoiceMessage/VoicePlaybackBubble.swift"))
        XCTAssertTrue(body.contains("guard waveform.isEmpty, decoded.isEmpty, let playableURL else { return }"))
    }

    /// The synchronous store is read from any thread the view happens to be
    /// built on.
    func testTheSynchronousStoreIsLocked() throws {
        let body = code(try source("Features/Chats/Presentation/VoiceMessage/VoiceWaveformCache.swift"))
        XCTAssertTrue(body.contains("private let lock = NSLock()"))
    }
}
