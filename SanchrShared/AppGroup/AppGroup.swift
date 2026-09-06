import Foundation
import Security

/// Shared identifiers for the App Group container, keychain access group,
/// and shared UserDefaults suite. Used by both the main app and the share
/// extension. Changing any of these is a breaking change for installed users.
public enum AppGroup {
    /// Apple App Group identifier. Must match the entry in both targets'
    /// .entitlements files and the provisioning profile.
    public static let identifier = "group.io.sanchr.shared"

    /// Bare suffix of the shared keychain access group, matching the
    /// `$(AppIdentifierPrefix)io.sanchr.shared` entry in both targets'
    /// entitlements plists.
    private static let keychainAccessGroupSuffix = "io.sanchr.shared"

    /// Fully-qualified keychain access group (`<TeamID>.io.sanchr.shared`)
    /// passed to `kSecAttrAccessGroup` at runtime. The team prefix is NOT
    /// auto-prepended by Security.framework — it must be the literal string
    /// that appears in the resolved entitlements. We discover it once by
    /// probing the keychain for a throwaway item: iOS returns the resolved
    /// access group in the item attributes, from which we extract the team
    /// prefix. Falls back to the bare suffix only if probing fails, which
    /// would indicate a missing entitlement (and will surface as -34018
    /// downstream rather than being silently masked).
    public static let keychainAccessGroup: String = {
        let probeService = "io.sanchr.shared.access-group-probe"
        let probeAccount = "probe"

        // Clean up any prior probe item before starting.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data([0x00]),
            kSecReturnAttributes as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var result: CFTypeRef?
        let status = SecItemAdd(addQuery as CFDictionary, &result)

        defer { SecItemDelete(deleteQuery as CFDictionary) }

        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let resolvedGroup = attrs[kSecAttrAccessGroup as String] as? String
        else {
            return keychainAccessGroupSuffix
        }

        // resolvedGroup is "<TeamID>.<app-id-suffix>" — e.g. "ABCD1234.com.sanchr.app".
        // Take the first dot-separated component as the team prefix and glue it
        // to our suffix so we get "<TeamID>.io.sanchr.shared".
        guard let teamPrefix = resolvedGroup.split(separator: ".").first else {
            return keychainAccessGroupSuffix
        }
        return "\(teamPrefix).\(keychainAccessGroupSuffix)"
    }()

    /// Shared UserDefaults suite. Same string as `identifier` by convention.
    public static var userDefaults: UserDefaults {
        guard let d = UserDefaults(suiteName: identifier) else {
            preconditionFailure("Unable to open shared UserDefaults suite \(identifier) — App Group entitlement missing?")
        }
        return d
    }

    /// Root URL for the shared container. Absence of the App Group
    /// entitlement is a programmer error in a shipped build, not a runtime
    /// condition to fall back from silently — so it still traps there.
    public static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        if let url = testContainerURL {
            return url
        }
        preconditionFailure("App Group container missing for \(identifier) — entitlement missing?")
    }

    /// A stand-in container for unsigned test runs.
    ///
    /// The real container needs the App Group entitlement, which needs a
    /// provisioning profile, which needs a signing identity that CI has no
    /// way to hold for fork pull requests. Without this the suite trapped
    /// before its first assertion, so the whole unit suite guarded nothing
    /// on a pull request and only ran on a developer's own machine.
    ///
    /// Gated on XCTest actually hosting the process, not on a build
    /// configuration: a shipped build whose entitlement went missing must
    /// still trip the precondition above rather than quietly write to a
    /// directory the share extension cannot read. Signed runs never reach
    /// this — the real container resolves first.
    private static let testContainerURL: URL? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SanchrTestContainer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

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

public enum ChatMediaVisibilityStore {
    private static func key(for conversationId: String) -> String {
        "sanchr.chatMediaVisibility.\(conversationId)"
    }

    public static func isVisibleInGallery(conversationId: String) -> Bool {
        let key = key(for: conversationId)
        if AppGroup.userDefaults.object(forKey: key) == nil {
            return true
        }
        return AppGroup.userDefaults.bool(forKey: key)
    }

    public static func setVisibleInGallery(_ isVisible: Bool, conversationId: String) {
        AppGroup.userDefaults.set(isVisible, forKey: key(for: conversationId))
    }
}

/// The App Group defaults keys the app lock is stored under.
///
/// Defined once, here, because they are read from two targets. The share
/// extension used to spell the screen-lock key as `"screenLockEnabled"` while
/// the app wrote `"sanchr.security.screenLockEnabled"` — so the extension never
/// saw a lock, its unlock screen could not render, and the share sheet opened
/// the database and listed every conversation with App Lock on.
public enum AppLockDefaultsKeys {
    public static let screenLockEnabled = "sanchr.security.screenLockEnabled"
    public static let biometricLockEnabled = "sanchr.security.biometricLockEnabled"
    public static let screenLockTimeout = "sanchr.security.screenLockTimeout"
    public static let screenshotProtection = "sanchr.security.screenshotProtection"

    /// Whether the app is locked at all: either lock flavour counts. The app's
    /// Security screen prefers the biometric flag, so an extension that checks
    /// only the screen-lock flag would still miss the common case.
    public static var isLockEnabled: Bool {
        AppGroup.userDefaults.bool(forKey: screenLockEnabled)
            || AppGroup.userDefaults.bool(forKey: biometricLockEnabled)
    }
}
