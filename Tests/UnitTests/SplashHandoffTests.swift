import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// A locked cold launch used to go lock → splash → app. The splash now
/// plays first and the brand mark glides into the lock screen.
final class SplashHandoffTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testTheGateFollowsTheSplash() throws {
        let app = try source("App/SanchrApp.swift")
        XCTAssertFalse(app.contains("} else if container.appLockManager.biometricLockEnabled && !hasAuthenticatedAtGate {"),
                       "the gate must not pre-empt the root")
        let splash = try XCTUnwrap(app.range(of: "if showSplash {"))
        let after = String(app[splash.upperBound...].prefix(700))
        XCTAssertTrue(after.contains("} else if needsGate {"))
        XCTAssertTrue(after.contains("AppLockGateView(isAuthenticated: $hasAuthenticatedAtGate, markNamespace: brandMark)"))
        XCTAssertTrue(app.contains("container.appLockManager.isLocked && !showSplash && !needsGate"),
                      "the foreground overlay must not stack on the gate")
    }

    func testTheMarkSharesGeometryAcrossBothScreens() throws {
        XCTAssertTrue(try source("Features/Auth/Presentation/SplashView.swift").contains(".brandMark(in: markNamespace)"))
        XCTAssertTrue(try source("SanchrShared/DesignSystem/LockScreenView.swift").contains(".brandMark(in: markNamespace)"))
        XCTAssertEqual(BrandMark.geometryID, "sanchr.brandMark")
    }
}
