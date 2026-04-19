import Foundation

// MARK: - SecurityNudge

/// Tracks whether the one-time Registration Lock nudge banner should be shown.
///
/// Logic:
///   - First launch date is recorded once and persisted.
///   - The banner appears after `nudgeDelayDays` days have elapsed.
///   - Once the user dismisses the banner **or** opens the Registration Lock screen,
///     the nudge is permanently suppressed (never shown again).
enum SecurityNudge {

    // MARK: - Keys

    private static let firstLaunchKey = "sanchr.security.firstLaunchDate"
    private static let nudgeDismissedKey = "sanchr.security.regLockNudgeDismissed"

    // MARK: - Configuration

    /// Number of days after first launch before the banner is eligible to appear.
    private static let nudgeDelayDays = 3

    // MARK: - API

    /// Records the first-launch date if this is the first time called on this installation.
    /// Safe to call multiple times — only writes once.
    static func recordFirstLaunchIfNeeded() {
        guard UserDefaults.standard.object(forKey: firstLaunchKey) == nil else { return }
        UserDefaults.standard.set(Date(), forKey: firstLaunchKey)
    }

    /// Whether the Registration Lock nudge banner should currently be displayed.
    ///
    /// Returns `true` only when:
    /// - The nudge has never been dismissed/acknowledged, AND
    /// - At least `nudgeDelayDays` days have passed since first launch.
    static var shouldShowRegistrationLockNudge: Bool {
        guard !UserDefaults.standard.bool(forKey: nudgeDismissedKey) else { return false }
        guard let firstLaunch = UserDefaults.standard.object(forKey: firstLaunchKey) as? Date else {
            return false
        }
        let elapsed = Date().timeIntervalSince(firstLaunch)
        return elapsed >= Double(nudgeDelayDays * 86_400)
    }

    /// Permanently suppresses the nudge banner. Called when the user either:
    /// - Dismisses the banner via the X button, or
    /// - Opens the Registration Lock settings screen from the banner.
    static func dismissRegistrationLockNudge() {
        UserDefaults.standard.set(true, forKey: nudgeDismissedKey)
    }
}
