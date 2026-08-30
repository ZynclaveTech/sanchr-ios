import AVFoundation
import XCTest

@testable import Sanchr

/// The gallery must not take the audio session from a call, and must take it
/// the rest of the time.
///
/// The first version inferred "a call is running" from
/// `AVAudioSession.sharedInstance().mode == .voiceChat`. That is wrong, and
/// wrong in a way that only shows up after a call: category and mode are
/// sticky, CallKit deactivating the session does not clear them, and nothing
/// in the call teardown resets them — so the mode reads `.voiceChat` for the
/// rest of the process and every video opened afterwards played silently.
final class GalleryAudioCallSignalTests: XCTestCase {

    /// The regression, stated as the property that was violated: whether a
    /// call is running cannot be read off the audio session's mode.
    func testCallStateIsNotInferredFromTheSessionMode() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Features/Chats/Presentation/Viewers/MediaGallery/GalleryAudioSession.swift"
                ),
            encoding: .utf8
        )
        // Comments may discuss the mode; code must not read it. Strip the
        // doc comments before checking, or the explanation of the bug trips
        // the guard against the bug.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(
            code.contains("sharedInstance().mode"),
            "call state must be passed in, not inferred from a sticky session mode"
        )
        XCTAssertTrue(
            source.contains("callInProgress: Bool"),
            "the caller has to supply the call state"
        )
    }

    /// A call owns the session outright: taking it would cut the call's audio,
    /// which is far worse than a silent video. Both entry points have to stand
    /// down, not just the one that configures.
    ///
    /// Asserted against the source rather than by calling them and inspecting
    /// `AVAudioSession`. An earlier version did exactly that and was wrong
    /// twice over: it depended on whatever the process-wide session happened to
    /// hold, so it reported success for the wrong reason and then failed the
    /// moment unrelated code left the session in a different state.
    func testBothEntryPointsStandDownForACall() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Features/Chats/Presentation/Viewers/MediaGallery/GalleryAudioSession.swift"
                ),
            encoding: .utf8
        )
        for entry in ["activateForPlayback(callInProgress: Bool)",
                      "deactivate(callInProgress: Bool)"] {
            let body = try XCTUnwrap(
                source.range(of: "static func \(entry) {").map {
                    String(source[$0.upperBound...].prefix(400))
                },
                "\(entry) is missing"
            )
            XCTAssertTrue(
                body.contains("guard !callInProgress"),
                "\(entry) must leave the session alone during a call"
            )
        }
    }

    // There is deliberately no test that activating without a call
    // reconfigures the session. Doing so mutates the process-wide
    // AVAudioSession, and an earlier version of this file did exactly that —
    // it passed on its own and broke three unrelated share tests through
    // ordering. The behaviour it would cover is a single AVAudioSession call;
    // the part worth guarding is which signal decides to make it, above.

}
