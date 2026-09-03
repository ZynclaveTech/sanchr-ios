import SanchrShared
import XCTest
@testable import Sanchr

final class ScreenshotDefaultAndOTPFieldTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func tearDown() {
        AppGroup.userDefaults.removeObject(forKey: AppLockDefaultsKeys.screenshotProtection)
        super.tearDown()
    }

    @MainActor
    func testScreenshotProtectionIsOnUntilTheUserTurnsItOff() {
        let defaults = AppGroup.userDefaults
        defaults.removeObject(forKey: AppLockDefaultsKeys.screenshotProtection)
        let fresh = AppLockManager()
        XCTAssertTrue(fresh.isScreenshotProtectionActive, "a private messenger blanks the app switcher by default")
        XCTAssertTrue(fresh.screenshotProtectionEnabled)

        fresh.screenshotProtectionEnabled = false
        let relaunched = AppLockManager()
        XCTAssertFalse(relaunched.isScreenshotProtectionActive, "an explicit off is kept")
    }

    func testTheHiddenCodeFieldDrawsNothing() throws {
        let otp = try String(contentsOf: Self.root.appendingPathComponent("Features/Auth/Presentation/OTPView.swift"), encoding: .utf8)
        let field = try XCTUnwrap(otp.range(of: "TextField(\"\", text: $viewModel.otpCode)"))
        let modifiers = String(otp[field.upperBound...].prefix(600))
        XCTAssertTrue(modifiers.contains(".foregroundColor(.clear)"), "the digits ghosted through the first box")
        XCTAssertTrue(modifiers.contains(".tint(.clear)"), "and so did the caret")
        XCTAssertTrue(modifiers.contains(".opacity(0.01)"), "still focusable")
    }
}
