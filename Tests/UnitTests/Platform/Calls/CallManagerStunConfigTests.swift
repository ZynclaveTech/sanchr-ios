import XCTest
import SanchrShared
@testable import Sanchr

/// Verifies that CallManager's ICE-server list comes from injected config,
/// not from a hard-coded constant. Each test drives `buildIceServersImpl`
/// directly so it can pin the exact behavior of every branch.
final class CallManagerStunConfigTests: XCTestCase {

    /// With no TURN credentials and a non-empty configured STUN list, the
    /// emitted ICE-server list contains exactly the configured STUN URLs and
    /// no implicit Google fallback.
    func test_buildIceServers_withConfiguredStun_doesNotAppendGoogleFallback() {
        let credentials = Sanchr_Calling_TurnCredentials()
        let configured = ["stun:stun.example.com:3478", "stun:stun-backup.example.com:3478"]

        let servers = CallManager.buildIceServersImpl(from: credentials, stunServers: configured)
        let emitted = servers.flatMap { $0.urlStrings }

        XCTAssertEqual(emitted, configured,
            "configured STUN list must be the only entries when no TURN is present, got \(emitted)")
        XCTAssertFalse(emitted.contains("stun:stun.l.google.com:19302"),
            "Google STUN must NOT be appended when the configured list is non-empty")
    }

    /// With TURN credentials present, the emitted list contains the TURN
    /// entry first, then the configured STUN entries — and no implicit
    /// Google fallback.
    func test_buildIceServers_withTurn_emitsTurnPlusConfiguredStun() {
        var credentials = Sanchr_Calling_TurnCredentials()
        credentials.urls = ["turn:turn.example.com:3478"]
        credentials.username = "user"
        credentials.credential = "pass"
        let configured = ["stun:stun.example.com:3478"]

        let servers = CallManager.buildIceServersImpl(from: credentials, stunServers: configured)
        let emitted = servers.flatMap { $0.urlStrings }

        XCTAssertEqual(emitted, ["turn:turn.example.com:3478", "stun:stun.example.com:3478"],
            "expected TURN-then-STUN ordering, got \(emitted)")
    }

    /// With no TURN credentials and an empty configured STUN list, the
    /// fallback Google STUN is the only emitted entry — calls degrade
    /// gracefully under misconfiguration.
    func test_buildIceServers_withEmptyConfiguredList_emitsGoogleFallback() {
        let servers = CallManager.buildIceServersImpl(
            from: Sanchr_Calling_TurnCredentials(),
            stunServers: []
        )
        let emitted = servers.flatMap { $0.urlStrings }

        XCTAssertEqual(emitted, ["stun:stun.l.google.com:19302"],
            "empty configured list must trigger exactly the Google STUN fallback, got \(emitted)")
    }
}
