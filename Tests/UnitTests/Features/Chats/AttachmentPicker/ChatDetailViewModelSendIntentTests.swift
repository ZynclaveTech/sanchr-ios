import XCTest
@testable import Sanchr

/// Smoke tests for `ChatDetailViewModel.send(intent:context:)`.
///
/// `ChatDetailViewModel`'s send pipeline depends on a number of concrete
/// platform types (`SessionService`, `MediaUploadManager`, `ChatDataSource`,
/// the Signal protocol manager, the local DB) that are not currently exposed
/// behind protocols, so we can't mock the full path here. Instead we exercise
/// the pure routing/formatting surface and assert the pass-through-bytes
/// contract on captured media via the static test hooks on the view model.
///
// TODO: deepen once VM dependencies are protocol-ized.
@MainActor
final class ChatDetailViewModelSendIntentTests: XCTestCase {

    func testSendIntentTextFallbackForLocation() {
        let payload = LocationPayload(
            latitude: 37.7749,
            longitude: -122.4194,
            horizontalAccuracyMeters: 12.0,
            capturedAtUnixMs: 1_700_000_000_000
        )

        let text = ChatDetailViewModel.locationFallbackText(payload)

        // The fallback MUST contain the raw lat/long and MUST NOT contain any
        // place name, city, or other reverse-geocoded data.
        XCTAssertTrue(text.contains("37.7749"))
        XCTAssertTrue(text.contains("-122.4194"))
        XCTAssertTrue(text.hasPrefix("[Location]"))
    }

    func testSendIntentRoutesCapturedMediaThroughMediaPath() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])
        let capture = CapturedMedia(
            kind: .photo,
            data: bytes,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 1024,
            height: 768,
            durationSeconds: nil
        )

        let staged = try ChatDetailViewModel.stageCapturedMediaForTesting(capture)

        // The media-send path receives a real on-disk URL with the original
        // bytes — not a re-encoded copy.
        let onDisk = try Data(contentsOf: staged.url)
        XCTAssertEqual(onDisk, bytes, "Captured media bytes must be passed through unchanged")
        XCTAssertEqual(staged.mimeType, "image/jpeg")

        try? FileManager.default.removeItem(at: staged.url)
    }

    func testContactFallbackContainsDisplayName() {
        let stripped = StrippedContact(
            displayName: "Ada Lovelace",
            phoneNumbers: ["+14155550123"],
            emails: []
        )
        let text = ChatDetailViewModel.contactFallbackText(stripped)
        XCTAssertEqual(text, "[Contact] Ada Lovelace")
    }
}
