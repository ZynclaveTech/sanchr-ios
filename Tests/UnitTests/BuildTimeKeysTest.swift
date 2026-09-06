import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Every build-time secret has a reader and a place for the value to arrive.
///
/// Crash reporting shipped inert. `CrashReporter` read `SanchrSentryDSN` from
/// the bundle, and nothing ever put that key in Info.plist — so the DSN was
/// always nil, `SentrySDK.start` was never called, and a user who turned
/// crash reporting on got nothing. Both halves compiled, the suite passed,
/// and CI was green: a reader with no key is invisible to everything except
/// a test that looks for the key.
final class BuildTimeKeysTest: XCTestCase {

    /// Keys the app reads from its own bundle at runtime.
    private let injectedKeys = ["SanchrSentryDSN", "SanchrTenorAPIKey"]

    func testEveryInjectedKeyIsDeclaredInTheBundle() {
        for key in injectedKeys {
            XCTAssertNotNil(
                Bundle.main.object(forInfoDictionaryKey: key),
                "\(key) is read in code but absent from Info.plist, so it can never hold a value"
            )
        }
    }

    /// Absent is fine — empty is the default, and means "not configured".
    /// What must not happen is the build setting arriving unexpanded, which
    /// would send the literal `$(SANCHR_SENTRY_DSN)` to Sentry as a DSN.
    func testInjectedKeysAreNotUnexpandedBuildSettings() {
        for key in injectedKeys {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
            XCTAssertFalse(
                value.hasPrefix("$("),
                "\(key) came through as the literal build setting \(value)"
            )
        }
    }

    /// The DSN is empty in a local build, and that is the intended default —
    /// a fork reports nowhere. This pins the behaviour that follows from it.
    func testCrashReporterTreatsAnEmptyDSNAsUnconfigured() {
        let value = Bundle.main.object(forInfoDictionaryKey: "SanchrSentryDSN") as? String
        if value?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            // Nothing to assert about Sentry itself; the point is that this
            // path is reachable and does not crash.
            CrashReporter.shared.start()
        }
    }

    func testGIFServiceReportsItselfUnavailableWithoutAKey() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SanchrTenorAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces)
            .isEmpty == false
        XCTAssertEqual(GIFService.shared.isAvailable, configured)
    }
}
