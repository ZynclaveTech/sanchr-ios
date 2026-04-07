import Foundation

/// Shared identifiers for the App Group container, keychain access group,
/// and shared UserDefaults suite. Used by both the main app and the share
/// extension. Changing any of these is a breaking change for installed users.
public enum AppGroup {
    /// Apple App Group identifier. Must match the entry in both targets'
    /// .entitlements files and the provisioning profile.
    public static let identifier = "group.io.sanchr.shared"

    /// Keychain access group passed to `kSecAttrAccessGroup` at runtime.
    /// Security.framework auto-prepends the team identifier prefix when
    /// the entitlement is granted, so we pass the bare suffix here.
    /// The corresponding entitlement (`$(AppIdentifierPrefix)io.sanchr.shared`)
    /// lives in `Sanchr.entitlements` and `SanchrShareExtension.entitlements`,
    /// where the build system resolves the placeholder at codesign time.
    public static let keychainAccessGroup = "io.sanchr.shared"

    /// Shared UserDefaults suite. Same string as `identifier` by convention.
    public static var userDefaults: UserDefaults {
        guard let d = UserDefaults(suiteName: identifier) else {
            preconditionFailure("Unable to open shared UserDefaults suite \(identifier) — App Group entitlement missing?")
        }
        return d
    }

    /// Root URL for the shared container. Force-unwraps because absence
    /// of the App Group entitlement is a programmer error, not a runtime
    /// condition we should silently fall back from.
    public static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            preconditionFailure("App Group container missing for \(identifier) — entitlement missing?")
        }
        return url
    }

    public static var databaseURL: URL {
        let dir = containerURL.appendingPathComponent("Database", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("db.sqlite")
    }

    public static var senderLockURL: URL {
        let dir = containerURL.appendingPathComponent("Locks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sender.lock")
    }

    public static var mediaCacheURL: URL {
        let dir = containerURL.appendingPathComponent("MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
