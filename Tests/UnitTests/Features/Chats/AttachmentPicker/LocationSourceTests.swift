import XCTest
import CoreLocation
@testable import Sanchr

final class LocationSourceTests: XCTestCase {
    func test_makePayload_mapsFieldsCorrectly() {
        let fake = CLLocation(coordinate: .init(latitude: 28.6, longitude: 77.2),
                              altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 0,
                              timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = LocationSource.makePayload(from: fake)
        XCTAssertEqual(payload.latitude, 28.6, accuracy: 0.0001)
        XCTAssertEqual(payload.longitude, 77.2, accuracy: 0.0001)
        XCTAssertEqual(payload.horizontalAccuracyMeters, 12)
        XCTAssertEqual(payload.capturedAtUnixMs, 1_700_000_000_000)
    }

    func test_timeout_producesError_notPayload() async {
        let source = LocationSource(timeout: 0.05)
        do {
            _ = try await source.requestOneShot()
            XCTFail("Expected timeout error")
        } catch LocationSource.Error.timeout {
            // expected
        } catch LocationSource.Error.denied {
            // Also acceptable on simulator without location permission — the test
            // is really guarding that no successful payload comes back.
        } catch {
            XCTFail("Expected .timeout or .denied, got \(error)")
        }
    }
}
