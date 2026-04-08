import XCTest
import SanchrShared

final class UserStatusFromPresenceTests: XCTestCase {

    func testOnlineMapsToOnline() {
        XCTAssertEqual(User.Status(from: .online), .online)
    }

    func testOfflineMapsToOffline() {
        XCTAssertEqual(User.Status(from: .offline), .offline)
    }

    func testHiddenMapsToOffline() {
        // Hidden is a peer-side privacy state. Locally we treat it as
        // offline so the rest of the UI doesn't need a new case.
        XCTAssertEqual(User.Status(from: .hidden), .offline)
    }

    func testUnspecifiedMapsToOffline() {
        XCTAssertEqual(User.Status(from: .unspecified), .offline)
    }

    func testUnrecognizedMapsToOffline() {
        XCTAssertEqual(User.Status(from: .UNRECOGNIZED(42)), .offline)
    }
}
