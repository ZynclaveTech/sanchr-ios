import Foundation
import LocalAuthentication
import UIKit
import SanchrShared

/// Manages app-level screen lock and biometric authentication enforcement.
/// Reads security preferences from UserDefaults (synced from SettingsViewModel)
/// and requires Face ID / Touch ID when the app returns to foreground.
@Observable
final class AppLockManager: @unchecked Sendable {

    // MARK: - State

    /// Whether the app is currently locked and requires authentication.
    private(set) var isLocked: Bool = false

    /// Whether screenshot protection is currently active.
    private(set) var isScreenshotProtectionActive: Bool = false

    /// Timestamp when the app last entered the background.
    private var backgroundedAt: Date?

    // MARK: - UserDefaults Keys

    /// Shared with the extension so the two can never disagree again.
    private typealias Keys = AppLockDefaultsKeys

    private static let migrationFlagKey = "applock_migrated_to_appgroup_v1"

    // MARK: - Init

    init() {
        let shared = AppGroup.userDefaults
        if shared.bool(forKey: Self.migrationFlagKey) == false {
            let std = UserDefaults.standard
            let migratedKeys = [
                Keys.screenLockEnabled,
                Keys.biometricLockEnabled,
                Keys.screenLockTimeout,
                Keys.screenshotProtection,
            ]
            for key in migratedKeys {
                if let value = std.object(forKey: key) {
                    shared.set(value, forKey: key)
                }
            }
            shared.set(true, forKey: Self.migrationFlagKey)
        }
        isScreenshotProtectionActive = shared.bool(forKey: Keys.screenshotProtection)
    }

    // MARK: - Preferences (read from UserDefaults)

    var screenLockEnabled: Bool {
        get { AppGroup.userDefaults.bool(forKey: Keys.screenLockEnabled) }
        set { AppGroup.userDefaults.set(newValue, forKey: Keys.screenLockEnabled) }
    }

    var biometricLockEnabled: Bool {
        get { AppGroup.userDefaults.bool(forKey: Keys.biometricLockEnabled) }
        set { AppGroup.userDefaults.set(newValue, forKey: Keys.biometricLockEnabled) }
    }

    var screenLockTimeout: Int32 {
        get { Int32(AppGroup.userDefaults.integer(forKey: Keys.screenLockTimeout)) }
        set { AppGroup.userDefaults.set(Int(newValue), forKey: Keys.screenLockTimeout) }
    }

    var screenshotProtectionEnabled: Bool {
        get { AppGroup.userDefaults.bool(forKey: Keys.screenshotProtection) }
        set {
            AppGroup.userDefaults.set(newValue, forKey: Keys.screenshotProtection)
            isScreenshotProtectionActive = newValue
        }
    }

    // MARK: - Sync from Server Settings

    /// Called after loading settings from the backend to persist locally.
    func syncFromSettings(
        screenLock: Bool,
        biometric: Bool,
        timeout: Int32,
        screenshotProtection: Bool
    ) {
        screenLockEnabled = screenLock
        biometricLockEnabled = biometric
        screenLockTimeout = timeout
        screenshotProtectionEnabled = screenshotProtection
    }

    // MARK: - Lifecycle Hooks

    /// Called when the app enters the background.
    func appDidEnterBackground() {
        backgroundedAt = Date()
        if screenLockEnabled || biometricLockEnabled {
            // Lock immediately if timeout is 0
            if screenLockTimeout == 0 {
                isLocked = true
            }
        }
    }

    /// Called when the app becomes active. Checks if lock timeout has elapsed.
    func appDidBecomeActive() {
        guard screenLockEnabled || biometricLockEnabled else {
            isLocked = false
            return
        }

        if let backgroundedAt {
            let elapsed = Date().timeIntervalSince(backgroundedAt)
            if elapsed >= TimeInterval(screenLockTimeout) {
                isLocked = true
            }
        }

        if isLocked {
            authenticate()
        }
    }

    // MARK: - Authentication

    /// Attempts biometric authentication and unlocks on success.
    func authenticate() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Biometrics unavailable — fall back to device passcode
            authenticateWithPasscode()
            return
        }

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock Sanchr"
                )
                if success {
                    isLocked = false
                    backgroundedAt = nil
                }
            } catch {
                SanchrLogger.auth.error("Biometric auth failed: \(error.localizedDescription)")
                // Don't unlock — user stays on lock screen
            }
        }
    }

    /// Falls back to device passcode when biometrics aren't available.
    private func authenticateWithPasscode() {
        let context = LAContext()

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock Sanchr"
                )
                if success {
                    isLocked = false
                    backgroundedAt = nil
                }
            } catch {
                SanchrLogger.auth.error("Passcode auth failed: \(error.localizedDescription)")
            }
        }
    }
}
