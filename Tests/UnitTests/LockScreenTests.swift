import Foundation
import LocalAuthentication
import SanchrShared
import UIKit
import XCTest

@testable import Sanchr

/// One lock screen for both surfaces, with copy that names the device's
/// real unlock method and stays quiet when the user cancels.
final class LockScreenTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testBothSurfacesShowTheSameScreen() throws {
        let gate = try source("Features/Auth/Presentation/AppLockGateView.swift")
        XCTAssertTrue(gate.contains("isAuthenticating: isAuthenticating,"))
        XCTAssertTrue(gate.contains("errorMessage: authError,"))
        XCTAssertTrue(gate.contains("onUnlock: authenticate,"))
        XCTAssertTrue(gate.contains("markNamespace: markNamespace"), "the gate hands the splash's mark through")
        let app = try source("App/SanchrApp.swift")
        XCTAssertTrue(app.contains("isAuthenticating: container.appLockManager.isAuthenticating"))
        XCTAssertTrue(app.contains("errorMessage: container.appLockManager.authError"))
    }

    func testTheButtonNamesTheMethod() {
        XCTAssertEqual(LockBiometry.faceID.buttonTitle, "Unlock with Face ID")
        XCTAssertEqual(LockBiometry.faceID.symbolName, "faceid")
        XCTAssertEqual(LockBiometry.touchID.buttonTitle, "Unlock with Touch ID")
        XCTAssertEqual(LockBiometry.passcode.buttonTitle, "Unlock")
        XCTAssertEqual(LockBiometry.passcode.symbolName, "lock.open.fill")
    }

    /// A cancel is the user's own doing; a lockout needs a way forward.
    func testCopyForFailures() {
        XCTAssertNil(LockScreenView.message(for: LAError(.userCancel)))
        XCTAssertNil(LockScreenView.message(for: LAError(.userFallback)))
        XCTAssertNil(LockScreenView.message(for: LAError(.notInteractive)), "could-not-prompt (\"User interaction is required\") is not a verdict")
        XCTAssertEqual(LockScreenView.message(for: LAError(.biometryLockout)), "Too many attempts. Use your passcode to unlock.")
        XCTAssertEqual(LockScreenView.message(for: LAError(.passcodeNotSet)), "Set a device passcode to unlock Sanchr.")
        XCTAssertNotNil(LockScreenView.message(for: LAError(.authenticationFailed)))
    }

    /// Backgrounding must not re-arm the cold-launch gate: with both it and
    /// the manager prompting on foreground, one of them always lost.
    func testTheBackgroundHandlerLeavesTheGateAlone() throws {
        let app = try source("App/SanchrApp.swift")
        let background = try XCTUnwrap(app.range(of: "case .background:"))
        let handler = String(app[background.upperBound...].prefix(1800))
        XCTAssertFalse(handler.contains("hasAuthenticatedAtGate = false"))
    }

    /// The manager exposes prompt state so the overlay can show it.
    /// The mark moved to a catalog both targets compile; the app must still
    /// find it under the same name.
    func testTheMarkStillResolvesInTheApp() {
        XCTAssertNotNil(UIImage(named: "SanchrLogo"))
    }

    /// The extension shows the same screen, with a way out.
    func testTheShareExtensionUsesTheSameScreen() throws {
        let share = try source("SanchrShareExtension/UI/ShareUnlockView.swift")
        XCTAssertTrue(share.contains("LockScreenView("))
        XCTAssertTrue(share.contains("onCancel: onCancel"))
        XCTAssertTrue(share.contains("subtitle: \"Unlock to share into Sanchr.\""))
        let project = try source("project.yml")
        XCTAssertEqual(project.components(separatedBy: "- path: Resources/BrandAssets.xcassets").count - 1, 2,
                       "the mark must be compiled into both the app and the extension")
    }

    func testTheLockManagerPublishesPromptState() throws {
        let manager = try source("Shared/Services/AppLockManager.swift")
        XCTAssertTrue(manager.contains("private(set) var isAuthenticating: Bool = false"))
        XCTAssertTrue(manager.contains("private(set) var authError: String?"))
        // One prompt path since the passcode fallback moved into the policy
        // itself; it must still refuse to stack a second prompt.
        XCTAssertEqual(manager.components(separatedBy: "guard !isAuthenticating else { return }").count - 1, 1,
                       "the prompt path must refuse to stack a second prompt")
    }
}
