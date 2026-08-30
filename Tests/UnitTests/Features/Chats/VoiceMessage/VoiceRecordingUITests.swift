import CoreGraphics
import Foundation
import XCTest

@testable import Sanchr

/// The recording UI: what each control does, and what it says it does.
final class VoiceRecordingUITests: XCTestCase {

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

    // MARK: - Cancelling

    /// A locked recording has no finger left to slide, so cancelling has to be
    /// a control. It only had a stop button, which meant stopping and then
    /// discarding from the preview.
    func testARecordingCanBeCancelledOutright() {
        let recording = VoiceMessageState.idle.applyPress(at: Date())
        XCTAssertEqual(recording.applyCancel(), .idle)
    }

    func testCancellingAnythingElseDoesNothing() {
        let recording = Recording(url: URL(fileURLWithPath: "/tmp/a"), durationMs: 2000, waveform: [])
        let preview = VoiceMessageState.preview(recording)
        XCTAssertEqual(preview.applyCancel(), preview)
        XCTAssertEqual(VoiceMessageState.idle.applyCancel(), .idle)
    }

    // MARK: - Starting hands-free

    /// Started from the VoiceOver action there is no finger holding anything,
    /// so the recording has to begin in the state that has buttons.
    func testARecordingCanStartLocked() {
        guard case .recording(_, _, let locked) =
            VoiceMessageState.idle.applyPress(at: Date(), locked: true)
        else { return XCTFail("expected a recording") }
        XCTAssertTrue(locked)
    }

    func testARecordingStartedByHandIsNotLocked() {
        guard case .recording(_, _, let locked) = VoiceMessageState.idle.applyPress(at: Date())
        else { return XCTFail("expected a recording") }
        XCTAssertFalse(locked)
    }

    // MARK: - Stopping a locked recording

    /// The stop button used to route through the release path, which returns
    /// the state *unchanged* when locked — so the recorder stopped, the
    /// session was torn down, and the HUD stayed on screen with the recording
    /// lost. `applyLockedStop` existed for this and was never called.
    func testStoppingALockedRecordingUsesTheTransitionMeantForIt() throws {
        let body = code(try composer)
        XCTAssertTrue(
            body.contains("state.applyLockedStop(recording: rec)"),
            "the stop button needs the locked transition, not the finger-release one"
        )
        XCTAssertFalse(
            body.contains("onStop: { Task { await stopRecording() } }"),
            "routing stop through the release path is the bug this guards"
        )
    }

    // MARK: - The gesture

    /// The drag used to live on the HUD, which only exists once recording has
    /// started — by which time the finger is already down, and a recogniser
    /// attached then never sees that touch.
    func testTheDragGestureLivesOnAViewThatExistsBeforeTheTouch() throws {
        let body = code(try composer)
        XCTAssertTrue(
            body.contains(".simultaneousGesture(dragGesture)"),
            "the gesture belongs on the container, which is present before the press"
        )
        XCTAssertFalse(
            body.contains(".gesture(dragGesture)"),
            "attached to the HUD it would never receive the in-flight touch"
        )
    }

    // MARK: - Too short

    /// The flag was written in two places and read in none, so letting go too
    /// quickly deleted the recording and said nothing.
    func testTooShortIsActuallyShown() throws {
        let body = code(try composer)
        XCTAssertTrue(
            body.contains("if showTooShortToast {"),
            "the flag has to be read somewhere, not only set"
        )
    }

    // MARK: - Waveform

    /// The first bar sits at x = 0, and `<=` counted it as played at progress
    /// 0 — so every un-played waveform carried a stray coloured tick.
    func testNothingIsPlayedAtZeroProgress() {
        XCTAssertFalse(VoiceWaveformView.isPlayed(barX: 0, progressX: 0))
        XCTAssertFalse(VoiceWaveformView.isPlayed(barX: 40, progressX: 0))
    }

    func testBarsBeforeTheHeadArePlayed() {
        XCTAssertTrue(VoiceWaveformView.isPlayed(barX: 0, progressX: 50))
        XCTAssertTrue(VoiceWaveformView.isPlayed(barX: 49, progressX: 50))
        XCTAssertFalse(VoiceWaveformView.isPlayed(barX: 50, progressX: 50))
    }

    // MARK: - Spoken duration

    /// "1:05" is read by VoiceOver as a time of day.
    func testDurationIsSpokenAsADuration() {
        XCTAssertEqual(RecordingHUD.spokenDuration(5), "5 seconds")
        XCTAssertEqual(RecordingHUD.spokenDuration(1), "1 second")
        XCTAssertEqual(RecordingHUD.spokenDuration(65), "1 minute, 5 seconds")
        XCTAssertEqual(RecordingHUD.spokenDuration(120), "2 minutes, 0 seconds")
    }
}
