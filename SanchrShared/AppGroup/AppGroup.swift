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
