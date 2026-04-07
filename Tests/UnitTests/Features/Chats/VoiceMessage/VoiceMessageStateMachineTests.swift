import XCTest
@testable import Sanchr

final class VoiceMessageStateMachineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let rec = Recording(
        url: URL(fileURLWithPath: "/tmp/voice-test.m4a"),
        durationMs: 2500,
        waveform: Array(repeating: 0.5, count: 64)
    )

    func test_idle_press_transitionsToRecording() {
        let result = VoiceMessageState.idle.applyPress(at: now)
        XCTAssertEqual(result, .recording(startedAt: now, dragOffset: .zero, locked: false))
    }

    func test_recording_dragLeftBeyondThreshold_transitionsToIdle() {
        let s: VoiceMessageState = .recording(startedAt: now, dragOffset: .zero, locked: false)
        let result = s.applyDrag(.init(width: -90, height: 0))
        XCTAssertEqual(result, .idle)
    }

    func test_recording_dragUpBeyondThreshold_locks() {
        let s: VoiceMessageState = .recording(startedAt: now, dragOffset: .zero, locked: false)
        let result = s.applyDrag(.init(width: 0, height: -90))
        XCTAssertEqual(result, .recording(startedAt: now, dragOffset: .init(width: 0, height: -90), locked: true))
    }

    func test_recording_releaseUnderMinDuration_returnsIdleWithToast() {
        let s: VoiceMessageState = .recording(startedAt: now, dragOffset: .zero, locked: false)
        let outcome = s.applyRelease(now: now.addingTimeInterval(0.5), recording: rec)
        XCTAssertEqual(outcome.state, .idle)
        XCTAssertTrue(outcome.shouldShowTooShortToast)
    }

    func test_recording_releaseAtOrAboveMinDuration_transitionsToPreview() {
        let s: VoiceMessageState = .recording(startedAt: now, dragOffset: .zero, locked: false)
        let outcome = s.applyRelease(now: now.addingTimeInterval(2.5), recording: rec)
        XCTAssertEqual(outcome.state, .preview(rec))
        XCTAssertFalse(outcome.shouldShowTooShortToast)
    }

    func test_recording_releaseWhileLocked_isIgnored() {
        let s: VoiceMessageState = .recording(startedAt: now, dragOffset: .zero, locked: true)
        let outcome = s.applyRelease(now: now.addingTimeInterval(2.5), recording: rec)
        XCTAssertEqual(outcome.state, s)
        XCTAssertFalse(outcome.shouldShowTooShortToast)
    }

    func test_recording_lockedStop_transitionsToPreview() {
        let s: VoiceMessageState = .recording(startedAt: now, dragOffset: .zero, locked: true)
        let result = s.applyLockedStop(recording: rec)
        XCTAssertEqual(result, .preview(rec))
    }

    func test_recording_interruption_promotesToPreview() {
        let s: VoiceMessageState = .recording(startedAt: now, dragOffset: .zero, locked: false)
        let result = s.applyInterruption(recording: rec)
        XCTAssertEqual(result, .preview(rec))
    }

    func test_preview_discard_returnsToIdle() {
        let result = VoiceMessageState.preview(rec).applyDiscard()
        XCTAssertEqual(result, .idle)
    }

    func test_preview_send_returnsToIdle() {
        let result = VoiceMessageState.preview(rec).applySend()
        XCTAssertEqual(result, .idle)
    }
}
