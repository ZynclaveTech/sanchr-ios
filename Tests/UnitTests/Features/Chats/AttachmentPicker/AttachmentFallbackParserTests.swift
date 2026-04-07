import XCTest
import SanchrShared
@testable import Sanchr

final class AttachmentFallbackParserTests: XCTestCase {
    func testParsesContactFallback() {
        let result = AttachmentFallbackParser.parse("[Contact] Jane Doe")
        XCTAssertEqual(result, .contact(displayName: "Jane Doe"))
    }

    func testParsesLocationFallback() {
        let result = AttachmentFallbackParser.parse("[Location] 37.7749,-122.4194")
        XCTAssertEqual(result, .location(latitude: 37.7749, longitude: -122.4194))
    }

    func testReturnsNilForPlainText() {
        XCTAssertNil(AttachmentFallbackParser.parse("hello world"))
    }

    func testReturnsNilForMalformedLocation() {
        XCTAssertNil(AttachmentFallbackParser.parse("[Location] not a number"))
        XCTAssertNil(AttachmentFallbackParser.parse("[Location] 37.0"))
        XCTAssertNil(AttachmentFallbackParser.parse("[Location] 37.0,bad"))
    }

    @MainActor
    func testRoundTripsThroughViewModelHelpers() {
        let stripped = StrippedContact(
            displayName: "Alice Example",
            phoneNumbers: ["+15551234567"],
            emails: []
        )
        let contactText = ChatDetailViewModel.contactFallbackText(stripped)
        XCTAssertEqual(
            AttachmentFallbackParser.parse(contactText),
            .contact(displayName: "Alice Example")
        )

        let payload = LocationPayload(
            latitude: 12.3456,
            longitude: -65.4321,
            horizontalAccuracyMeters: 10,
            capturedAtUnixMs: 1_700_000_000_000
        )
        let locationText = ChatDetailViewModel.locationFallbackText(payload)
        XCTAssertEqual(
            AttachmentFallbackParser.parse(locationText),
            .location(latitude: 12.3456, longitude: -65.4321)
        )
    }
}
