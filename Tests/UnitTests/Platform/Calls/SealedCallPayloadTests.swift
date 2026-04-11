// Tests/UnitTests/Platform/Calls/SealedCallPayloadTests.swift
import XCTest
@testable import Sanchr

final class SealedCallPayloadTests: XCTestCase {

    func test_roundTrip_encodeDecode() throws {
        let original = SealedCallPayload(
            sdp: "v=0\r\no=- 46117317 2 IN IP4 127.0.0.1",
            dtlsFingerprint: "sha-256 AA:BB:CC:DD",
            paddingUntil: 1_000_000,
            timestamp: 999_999
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SealedCallPayload.self, from: data)

        XCTAssertEqual(decoded.sdp, original.sdp)
        XCTAssertEqual(decoded.dtlsFingerprint, original.dtlsFingerprint)
        XCTAssertEqual(decoded.paddingUntil, original.paddingUntil)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }

    func test_jsonKeys_areSnakeCase() throws {
        let payload = SealedCallPayload(
            sdp: "v=0", dtlsFingerprint: "sha-256 FF", paddingUntil: 1, timestamp: 2
        )
        let json = try JSONEncoder().encode(payload)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        XCTAssertNotNil(dict["dtls_fingerprint"])
        XCTAssertNotNil(dict["padding_until"])
        XCTAssertNil(dict["dtlsFingerprint"])   // must be snake_case
        XCTAssertNil(dict["paddingUntil"])
    }
}
