import AVFoundation
import XCTest

@testable import Sanchr

/// The audio session a call claims has to be given back.
///
/// `configureAudioSession` took it and nothing returned it, so whatever was
/// playing before never resumed, and the session read as `.playAndRecord` /
/// `.voiceChat` for the rest of the process — which is how gallery video ended
/// up silent after any call.
///
/// Checked at the source. Exercising this properly needs a real call: the
/// simulator has no CallKit call to end, and a test that drove the process-wide
/// `AVAudioSession` for real would break unrelated suites through ordering, as
/// one in this repo already did.
final class CallAudioTeardownTests: XCTestCase {

    private var webRTCSource: String {
        get throws {
            try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Platform/Calls/WebRTCClient.swift"),
                encoding: .utf8
            )
        }
    }

    /// Every teardown path goes through `close()`, so the release belongs there
    /// rather than at the four call sites that would each have to remember it.
    func testClosingACallReleasesTheSession() throws {
        let source = try webRTCSource
        let closeBody = try XCTUnwrap(
            source.range(of: "func close() {").map {
                String(source[$0.upperBound...].prefix(900))
            }
        )
        XCTAssertTrue(
            closeBody.contains("releaseAudioSession()"),
            "closing a call must hand the audio session back"
        )
    }

    /// Without this flag other apps stay stopped: deactivating quietly is what
    /// leaves music paused after a call.
    func testOtherAppsAreToldSoTheyCanResume() throws {
        XCTAssertTrue(
            try webRTCSource.contains("notifyOthersOnDeactivation"),
            "deactivating without notifying leaves other audio stopped"
        )
    }

    /// The half that deactivation alone does not fix. Category and mode
    /// persist, so the session keeps reading as a call until something resets
    /// it.
    func testTheCategoryIsResetNotJustDeactivated() throws {
        XCTAssertTrue(
            try webRTCSource.contains("setCategory(.ambient"),
            "a deactivated session still reports .playAndRecord/.voiceChat"
        )
    }

    /// Taken under WebRTC's own lock, or WebRTC can reconfigure the session
    /// midway through it being handed back.
    func testTheHandbackIsTakenUnderWebRTCsLock() throws {
        let source = try webRTCSource
        let releaseBody = try XCTUnwrap(
            source.range(of: "private func releaseAudioSession() {").map {
                String(source[$0.upperBound...].prefix(1400))
            }
        )
        XCTAssertTrue(releaseBody.contains("lockForConfiguration()"))
        XCTAssertTrue(releaseBody.contains("unlockForConfiguration()"))
    }

    /// A call that has already ended must not be able to fail here, so every
    /// step is best-effort.
    func testTeardownCannotThrow() throws {
        let source = try webRTCSource
        let releaseBody = try XCTUnwrap(
            source.range(of: "private func releaseAudioSession() {").map {
                String(source[$0.upperBound...].prefix(1400))
            }
        )
        XCTAssertFalse(
            releaseBody.contains("try session.setActive(false, options:") == false,
            "the deactivation call should be present"
        )
        XCTAssertTrue(
            releaseBody.contains("catch"),
            "teardown must swallow its failures rather than propagate them"
        )
    }
}
