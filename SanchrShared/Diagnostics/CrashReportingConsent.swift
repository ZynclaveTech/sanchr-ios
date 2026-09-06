import Foundation

/// Whether crash reports may leave the device.
///
/// Off by default, deliberately. A crash report carries a stack trace and
/// device details to a third party, and this app's premise is that nothing
/// about a conversation goes anywhere the user did not send it. Sending
/// diagnostics is the user's call, not a default.
///
/// Matches Android, where the same preference defaults to off.
public enum CrashReportingConsent {
    public static let storageKey = "sanchr.crashReportingEnabled"

    /// Whether the user has allowed crash reporting.
    ///
    /// `UserDefaults.bool` returns false for an unset key, which is the
    /// default we want, so absence and refusal read the same.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: storageKey)
    }
}
