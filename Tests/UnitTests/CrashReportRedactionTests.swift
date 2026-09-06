import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// A crash report leaves the device, so what it may say is a privacy
/// boundary, not a formatting preference.
///
/// Mirrors Android's `CrashReportRedactionTest` case for case: a report from
/// either platform has to withhold the same things, or the platform with the
/// weaker rule sets the real one.
final class CrashReportRedactionTests: XCTestCase {

    func testRedactsEmailAddress() {
        XCTAssertEqual(
            CrashReportRedaction.redact("failed for aria@example.com while syncing"),
            "failed for [email] while syncing"
        )
    }

    func testRedactsPhoneNumber() {
        XCTAssertEqual(
            CrashReportRedaction.redact("no session for +91 98765 43210"),
            "no session for [phone]"
        )
    }

    /// Phone before path and base64: a long digit run is also a base64 match,
    /// and losing the race leaves a half-redacted number on the wire.
    func testRedactsPhoneEvenWhenItCouldParseAsData() {
        let redacted = CrashReportRedaction.redact("+919876543210")
        XCTAssertFalse(redacted.contains("9876543210"))
    }

    func testRedactsFileURL() {
        XCTAssertEqual(
            CrashReportRedaction.redact("cannot open file:///var/mobile/Media/img.jpg"),
            "cannot open [url]"
        )
    }

    func testRedactsFilesystemPath() {
        let redacted = CrashReportRedaction.redact("missing /var/mobile/Containers/Data/attachment.enc")
        XCTAssertFalse(redacted.contains("attachment.enc"))
        XCTAssertTrue(redacted.contains("[path]"))
    }

    func testRedactsLongBase64Run() {
        let redacted = CrashReportRedaction.redact("key=MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE")
        XCTAssertEqual(redacted, "key=[data]")
    }

    func testLeavesOrdinaryDiagnosticTextAlone() {
        let text = "decrypt failed: bad MAC"
        XCTAssertEqual(CrashReportRedaction.redact(text), text)
    }

    func testEmptyAndNilCollapseToEmptyString() {
        XCTAssertEqual(CrashReportRedaction.redact(nil), "")
        XCTAssertEqual(CrashReportRedaction.redact("   "), "")
    }

    /// The summary is what `recordHandled` sends instead of the error's own
    /// text, so it must not carry the text at all.
    func testSummaryCarriesTypeAndDomainButNotMessage() {
        let error = NSError(
            domain: "com.sanchr.transport",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "failed for +91 98765 43210"]
        )
        let summary = CrashReportRedaction.summarise(error)
        XCTAssertTrue(summary.contains("com.sanchr.transport"))
        XCTAssertTrue(summary.contains("code=7"))
        XCTAssertFalse(summary.contains("98765"))
    }
}

/// Consent gates whether the SDK starts at all, so its default is the whole
/// privacy claim: an install that is never touched reports nothing.
final class CrashReportingConsentTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CrashReportingConsentTests")!
        defaults.removePersistentDomain(forName: "CrashReportingConsentTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "CrashReportingConsentTests")
        super.tearDown()
    }

    func testDefaultsToOff() {
        XCTAssertFalse(CrashReportingConsent.isEnabled(defaults: defaults))
    }

    func testRoundTrips() {
        CrashReportingConsent.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CrashReportingConsent.isEnabled(defaults: defaults))
        CrashReportingConsent.setEnabled(false, defaults: defaults)
        XCTAssertFalse(CrashReportingConsent.isEnabled(defaults: defaults))
    }
}
