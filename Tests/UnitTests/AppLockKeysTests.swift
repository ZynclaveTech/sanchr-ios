import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// The app and its share extension have to agree on where the lock lives.
///
/// They did not. The extension spelled the key `"screenLockEnabled"` while the
/// app wrote `"sanchr.security.screenLockEnabled"`, so the extension never saw
/// a lock — its unlock screen could not render, and the share sheet opened the
/// database and listed every conversation with App Lock on.
final class AppLockKeysTests: XCTestCase {

    private let defaults = AppGroup.userDefaults

    override func tearDown() {
        defaults.removeObject(forKey: AppLockDefaultsKeys.screenLockEnabled)
        defaults.removeObject(forKey: AppLockDefaultsKeys.biometricLockEnabled)
        super.tearDown()
    }

    /// What the app writes, the extension reads — same key, same suite.
    func testWhatTheAppWritesIsWhatTheExtensionReads() {
        let manager = AppLockManager()
        manager.screenLockEnabled = true
        XCTAssertTrue(AppLockDefaultsKeys.isLockEnabled)

        manager.screenLockEnabled = false
        XCTAssertFalse(AppLockDefaultsKeys.isLockEnabled)
    }

    /// The Security screen prefers the biometric flag, so an extension that
    /// checked only the screen-lock flag would miss the common case.
    func testBiometricLockAloneIsEnoughToLockTheExtension() {
        let manager = AppLockManager()
        manager.biometricLockEnabled = true
        XCTAssertTrue(AppLockDefaultsKeys.isLockEnabled)
    }

    /// No target may spell the key by hand again.
    func testNeitherTargetHardcodesTheKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["SanchrShareExtension/UI/ShareRootView.swift", "Shared/Services/AppLockManager.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(
                text.contains("\"screenLockEnabled\"") || text.contains("\"sanchr.security.screenLockEnabled\""),
                "\(path) must read the key through AppLockDefaultsKeys"
            )
        }
    }
}
