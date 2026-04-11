// Tests/UnitTests/Platform/Calls/WebRTCClientFingerprintTests.swift
import XCTest
@testable import Sanchr
import WebRTC

final class WebRTCClientFingerprintTests: XCTestCase {

    func test_extractFingerprint_parsesLineCorrectly() {
        let sdp = RTCSessionDescription(type: .offer, sdp: """
            v=0\r
            o=- 1 2 IN IP4 127.0.0.1\r
            a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF\r
            a=setup:actpass\r
            """)
        let result = WebRTCClient.extractDtlsFingerprint(from: sdp)
        XCTAssertEqual(result, "sha-256 AA:BB:CC:DD:EE:FF")
    }

    func test_extractFingerprint_returnsNilWhenAbsent() {
        let sdp = RTCSessionDescription(type: .offer, sdp: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n")
        XCTAssertNil(WebRTCClient.extractDtlsFingerprint(from: sdp))
    }
}
