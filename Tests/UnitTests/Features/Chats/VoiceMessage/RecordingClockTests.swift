import Foundation
import XCTest

@testable import Sanchr

/// The recording clock and the objects behind it.
///
/// On device the timer sat at 0:00 and the waveform never moved. Two causes,
/// both of them about a view being re-made underneath a running task.
final class RecordingClockTests: XCTestCase {

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

    private var composer: String {
        get throws { try source("Features/Chats/Presentation/VoiceMessage/VoiceMessageComposer.swift") }
    }

    private var hud: String {
        get throws { try source("Features/Chats/Presentation/VoiceMessage/RecordingHUD.swift") }
    }

    /// The recorder must survive the view being re-made.
    ///
    /// As a plain `let` on a view struct it was rebuilt whenever SwiftUI
    /// re-initialised the composer, so the task reading `meterStream` and the
    /// call to `start()` ended up on different objects, and the meters were
    /// delivered to a stream nobody was reading.
    func testTheRecorderIsOwnedRatherThanRebuilt() throws {
        let body = code(try composer)
        XCTAssertTrue(
            body.contains("@State private var recorder = VoiceRecorder()"),
            "a plain let is rebuilt on every re-init, orphaning the meter stream"
        )
    }

    /// The clock must not depend on something else happening to redraw.
    ///
    /// Elapsed time was recomputed only when the composer's body ran again,
    /// and the thing driving that was a `@State` the body never read — which
    /// SwiftUI has no reason to re-evaluate over.
    func testTheClockDrivesItself() throws {
        let hudBody = code(try hud)
        XCTAssertTrue(
            hudBody.contains("TimelineView(.periodic(from: startedAt, by: 0.1))"),
            "the HUD needs its own clock, not one handed to it on someone else's schedule"
        )
        let composerBody = code(try composer)
        XCTAssertFalse(
            composerBody.contains("elapsed += 0.1"),
            "mutating unread state to force a redraw is what broke"
        )
        XCTAssertFalse(
            composerBody.contains("Date().timeIntervalSince(startedAt)"),
            "the elapsed time should not be computed where it cannot be refreshed"
        )
    }
}
