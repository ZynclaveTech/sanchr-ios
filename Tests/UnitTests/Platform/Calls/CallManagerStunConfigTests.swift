import XCTest
import SanchrShared
@testable import Sanchr

/// Verifies that CallManager's STUN fallback list comes from
/// AppConfiguration, not from a hard-coded constant.
final class CallManagerStunConfigTests: XCTestCase {

    /// When the gRPC TurnCredentials response carries no TURN URLs, the
    /// resulting RTCIceServer list must contain every STUN URL from
    /// AppConfiguration.current.stunServers — not just the default Google STUN.
    func test_buildIceServers_withoutTurn_emitsConfiguredStunList() {
        let credentials = Sanchr_Calling_TurnCredentials()  // empty — no TURN
        let configured = AppConfiguration.current.stunServers
        XCTAssertFalse(configured.isEmpty,
            "AppConfiguration.current must declare at least one STUN server")

        let servers = CallManager.testOnly_buildIceServers(from: credentials)

        // Every configured STUN URL must appear in the returned servers.
        let emitted: [String] = servers.flatMap { $0.urlStrings }
        for stun in configured {
            XCTAssertTrue(emitted.contains(stun),
                "expected configured STUN '\(stun)' in iceServers, got \(emitted)")
        }
    }

    /// When the gRPC response includes TURN credentials, both the TURN entry
    /// and the configured STUN entries must be present.
    func test_buildIceServers_withTurn_emitsTurnPlusConfiguredStun() {
        var credentials = Sanchr_Calling_TurnCredentials()
        credentials.urls = ["turn:turn.example.com:3478"]
        credentials.username = "user"
        credentials.credential = "pass"

        let servers = CallManager.testOnly_buildIceServers(from: credentials)
        let emitted: [String] = servers.flatMap { $0.urlStrings }

        XCTAssertTrue(emitted.contains("turn:turn.example.com:3478"),
            "TURN entry must be present, got \(emitted)")
        for stun in AppConfiguration.current.stunServers {
            XCTAssertTrue(emitted.contains(stun),
                "configured STUN '\(stun)' must still be present alongside TURN")
        }
    }
}
