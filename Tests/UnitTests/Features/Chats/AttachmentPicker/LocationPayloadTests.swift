import XCTest
@testable import Sanchr

final class LocationPayloadTests: XCTestCase {
    func test_jsonKeys_areFrozen() throws {
        let p = LocationPayload(latitude: 28.6139, longitude: 77.2090,
                                horizontalAccuracyMeters: 15.0, capturedAtUnixMs: 1_700_000_000_000)
        let data = try JSONEncoder().encode(p)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(dict.keys),
                       Set(["latitude", "longitude", "horizontalAccuracyMeters", "capturedAtUnixMs"]))
    }

    func test_noPlaceName_noDeviceId_noSessionId() throws {
        let p = LocationPayload(latitude: 0, longitude: 0, horizontalAccuracyMeters: 0, capturedAtUnixMs: 0)
        let json = String(data: try JSONEncoder().encode(p), encoding: .utf8)!
        XCTAssertFalse(json.lowercased().contains("place"))
        XCTAssertFalse(json.lowercased().contains("device"))
        XCTAssertFalse(json.lowercased().contains("session"))
    }
}
