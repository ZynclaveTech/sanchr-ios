import XCTest

@testable import Sanchr

/// Which QR payloads name a Sanchr user.
///
/// The scanner and the sheet behind it each had their own rule. The sheet's
/// — the one that picked the user out — took any host ending in the letters
/// `sanchr.com`, any scheme, and any text as the id.
final class QRContactCodeTests: XCTestCase {
    private let id = "0f8fad5b-d9cb-469f-a165-70867728950e"

    func test_ourOwnProfileLinkNamesItsUser() {
        XCTAssertEqual(ProfileLink.userId(from: "https://sanchr.com/u/\(id)"), id)
        XCTAssertEqual(ProfileLink.userId(from: "https://www.sanchr.com/u/\(id)"), id)
        XCTAssertTrue(QRScannerView.isSanchrContactCode("https://sanchr.com/u/\(id)"))
    }

    func test_whatAProfileShowsIsWhatAScannerReads() {
        XCTAssertEqual(ProfileLink.userId(from: ProfileLink.link(userId: id)), id)
    }

    /// Android writes ids in lower case; a link typed or re-encoded in upper
    /// case names the same user.
    func test_caseDoesNotMatter() {
        XCTAssertEqual(ProfileLink.userId(from: "HTTPS://SANCHR.COM/u/\(id.uppercased())"), id)
    }

    func test_surroundingWhitespaceIsIgnored() {
        XCTAssertEqual(ProfileLink.userId(from: "  https://sanchr.com/u/\(id)\n"), id)
    }

    func test_aHostThatOnlyEndsInTheNameIsRejected() {
        XCTAssertNil(ProfileLink.userId(from: "https://evilsanchr.com/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com.evil.example/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://evil.example/?next=sanchr.com/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://anything.sanchr.com/u/\(id)"))
        XCTAssertFalse(QRScannerView.isSanchrContactCode("https://evilsanchr.com/u/\(id)"))
    }

    func test_onlyHttpsCounts() {
        XCTAssertNil(ProfileLink.userId(from: "http://sanchr.com/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "sanchr://sanchr.com/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "sanchr.com/u/\(id)"))
    }

    func test_nothingMayRideAlong() {
        XCTAssertNil(ProfileLink.userId(from: "https://user@sanchr.com/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com@evil.example/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com:8443/u/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/u/\(id)?x=1"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/u/\(id)#x"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/u/\(id)/more"))
    }

    func test_theIdMustLookLikeAUserId() {
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/u/abc-123"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/u/"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/u/..%2F\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/x/\(id)"))
        XCTAssertNil(ProfileLink.userId(from: "https://sanchr.com/download"))
    }

    func test_nonsenseIsRejectedRatherThanCrashing() {
        XCTAssertNil(ProfileLink.userId(from: ""))
        XCTAssertNil(ProfileLink.userId(from: "WIFI:S:home;T:WPA;P:hunter2;;"))
        XCTAssertFalse(QRScannerView.isSanchrContactCode(""))
    }
}
