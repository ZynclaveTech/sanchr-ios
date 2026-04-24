// Tests/UnitTests/AppConfigurationTests.swift
import XCTest
@testable import SanchrShared

final class AppConfigurationTests: XCTestCase {
    func test_production_hasNoClientSideTurnServerList() {
        // TURN credentials come exclusively from the server's GetTurnCredentials RPC.
        // AppConfiguration must not carry a static TURN list — that field was dead
        // code that misrepresented where TURN configuration lives.
        let mirror = Mirror(reflecting: AppConfiguration.production)
        XCTAssertFalse(
            mirror.children.contains(where: { $0.label == "turnServers" }),
            "AppConfiguration must not expose a turnServers field — TURN is server-issued"
        )
    }
}
