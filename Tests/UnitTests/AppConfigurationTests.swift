import XCTest
import SanchrShared

final class AppConfigurationTests: XCTestCase {
    /// Pins the absence of a `turnServers` field on `AppConfiguration`. TURN
    /// credentials come exclusively from `CallSignalingService.GetTurnCredentials`
    /// at call time and must not be hard-coded client-side.
    ///
    /// Limitation: this test only catches re-introduction under the exact name
    /// `turnServers`. A field renamed (e.g. `staticTurnServers`) would slip
    /// through — the intent is to prevent the specific mistake we just removed,
    /// not to enforce a generic "no TURN config" invariant.
    func test_appConfiguration_doesNotExposeTurnServersField() {
        // Type-shape check, not instance-data — reflect on the smallest factory.
        let mirror = Mirror(reflecting: AppConfiguration.development)
        XCTAssertFalse(
            mirror.children.contains(where: { $0.label == "turnServers" }),
            "AppConfiguration must not expose a turnServers field — TURN is server-issued"
        )
    }
}
