import Foundation
import XCTest

@testable import Sanchr

/// The App Lock gate must accept the device passcode.
///
/// It requested `.deviceOwnerAuthenticationWithBiometrics`, so a user
/// without Face ID / Touch ID enrolled — or whose Face ID failed — had no
/// way past the gate. The share extension's unlock already used
/// `.deviceOwnerAuthentication`; the two must stay on the same policy.
final class AppLockGatePolicyTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// Comment lines are dropped so the doc comment naming the policy does
    /// not count as a use.
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheGateFallsBackToTheDevicePasscode() throws {
        let gate = code(try source("Features/Auth/Presentation/AppLockGateView.swift"))
        XCTAssertFalse(gate.contains(".deviceOwnerAuthenticationWithBiometrics"))
        XCTAssertEqual(gate.components(separatedBy: ".deviceOwnerAuthentication").count - 1, 2,
                       "both the availability check and the evaluation must use the passcode-fallback policy")
    }

    func testTheGateAndTheShareUnlockAgree() throws {
        let share = try source("SanchrShareExtension/UI/ShareUnlockView.swift")
        XCTAssertTrue(share.contains("canEvaluatePolicy(.deviceOwnerAuthentication,"))
        XCTAssertFalse(share.contains(".deviceOwnerAuthenticationWithBiometrics"))
    }
}
