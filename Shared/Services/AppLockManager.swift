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

    /// A prompt is on screen. The lock screen disables its button meanwhile.
    private(set) var isAuthenticating: Bool = false

    /// Why the last prompt did not unlock, for the lock screen to show. Nil
    /// when the user simply cancelled — that needs no explanation.
    private(set) var authError: String?

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
        // On by default for a private messenger: nothing had ever written the
        // key, so `bool(forKey:)` read false and the app-switcher snapshot
        // showed the chat list. An explicit choice, either way, is kept.
        if shared.object(forKey: Keys.screenshotProtection) == nil {
            shared.set(true, forKey: Keys.screenshotProtection)
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

    /// App Lock is on when either flavour is: the Security screen turns on
    /// `screenLockEnabled` alone when a timeout is picked without Face ID.
    /// The cold-launch gate used to check only the biometric flag, so that
    /// configuration locked the share extension but never the app.
    var isLockConfigured: Bool { screenLockEnabled || biometricLockEnabled }

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
        if isLockConfigured {
            // Lock immediately if timeout is 0
            if screenLockTimeout == 0 {
                isLocked = true
            }
        }
    }

    /// Called when the app becomes active. Checks if lock timeout has elapsed.
    func appDidBecomeActive() {
        guard isLockConfigured else {
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

    /// Prompts to unlock. `.deviceOwnerAuthentication`, the same policy as
    /// the cold-launch gate and the share extension: iOS tries Face ID or
    /// Touch ID first and offers the passcode itself, including after a
    /// biometry lockout. The biometrics-only policy this used before told a
    /// locked-out user to "use your passcode" with no way to enter it.
    func authenticate() {
        guard !isAuthenticating else { return }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authError = error.map(LockScreenView.message(for:)) ?? "Set a device passcode to unlock Sanchr."
            return
        }

        isAuthenticating = true
        authError = nil
        Task {
            defer { isAuthenticating = false }
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock Sanchr"
                )
                if success {
                    isLocked = false
                    backgroundedAt = nil
                } else {
                    authError = "Couldn't unlock. Try again."
                }
            } catch {
                SanchrLogger.auth.error("App unlock failed: \(error.localizedDescription)")
                // Don't unlock — user stays on lock screen
                authError = LockScreenView.message(for: error)
            }
        }
    }
}
