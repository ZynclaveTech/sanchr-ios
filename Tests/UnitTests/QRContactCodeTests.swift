import XCTest

@testable import Sanchr

/// Which QR payloads count as a Sanchr contact code.
///
/// The check was `code.contains("sanchr.com")` — a substring match anywhere in
/// the payload — so a link to any host that merely mentioned the domain was
/// accepted and handed to the add-contact flow.
final class QRContactCodeTests: XCTestCase {
    func test_ourOwnProfileLinkIsAccepted() {
        XCTAssertTrue(QRScannerView.isSanchrContactCode("https://sanchr.com/u/abc-123"))
        XCTAssertTrue(QRScannerView.isSanchrContactCode("https://www.sanchr.com/u/abc-123"))
    }

    func test_anotherHostMentioningTheDomainIsRejected() {
        XCTAssertFalse(QRScannerView.isSanchrContactCode("https://evil.example/?next=sanchr.com/u/abc"))
        XCTAssertFalse(QRScannerView.isSanchrContactCode("https://sanchr.com.evil.example/u/abc"))
        XCTAssertFalse(QRScannerView.isSanchrContactCode("sanchr.com"))
    }

    func test_nonsenseIsRejectedRatherThanCrashing() {
        XCTAssertFalse(QRScannerView.isSanchrContactCode(""))
        XCTAssertFalse(QRScannerView.isSanchrContactCode("WIFI:S:home;T:WPA;P:hunter2;;"))
    }

    func test_surroundingWhitespaceIsIgnored() {
        XCTAssertTrue(QRScannerView.isSanchrContactCode("  https://sanchr.com/u/abc-123\n"))
    }
}
