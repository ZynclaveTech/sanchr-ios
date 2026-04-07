import Foundation

/// One-shot migration from per-app sandbox paths to the shared App Group
/// container. Idempotent: gated on a flag in the shared `UserDefaults` suite.
///
/// MUST run in the main app process. The share extension is too memory- and
/// time-constrained to move large database files, and only the main app is
/// guaranteed to have access to the legacy per-app sandbox during a normal
/// foreground launch.
///
/// All errors are non-fatal: a failed migration logs and returns rather than
/// crashing app launch. The flag is only set when the run reaches a clean
/// terminal state (clean install, destination already populated, or a
/// successful copy of every present sidecar).
///
/// **Keychain re-grouping is intentionally omitted.** iOS keychain items
/// written without an explicit `accessGroup` belong to the app's default
/// group (`<TeamID>.<bundleID>`). With the keychain-access-groups entitlement
/// from Task 10, *new* writes target `AppGroup.keychainAccessGroup`. Old
/// items remain readable from the main app but not from the extension. This
/// is acceptable for v1: the only data the extension needs (Signal identity
/// + session state) lives in the GRDB-backed crypto stores, which migrate
/// via the database move below. The keychain currently holds only the auth
/// token, which the extension can re-fetch on first use. If a future change
/// puts something extension-critical in the keychain, that change MUST add
/// explicit re-saving here.
public enum AppGroupMigration {

    private static let migrationFlagKey = "appgroup_migration_v1_completed"

    /// Pre-App-Group database location, retained here for migration only.
    ///
    /// Mirrors the historical default produced by
    /// `LocalDatabase.resolveDatabasePath(customPath:)`:
    /// `~/Library/Application Support/SanchrDB/sanchr.sqlite`.
    public static var legacyDatabaseURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport
            .appendingPathComponent("SanchrDB", isDirectory: true)
            .appendingPathComponent("sanchr.sqlite")
    }

    /// Returns true once migration has completed (or was unnecessary).
    public static var isComplete: Bool {
        AppGroup.userDefaults.bool(forKey: migrationFlagKey)
    }

    /// Run on every main-app launch. No-op if already complete, if the
    /// legacy database does not exist (clean install), or if the destination
    /// is already populated (assume a previous half-run; do not clobber).
    ///
    /// Never throws. All failures are caught, logged via
    /// `SanchrLogger.persistence`, and the flag is left unset so a future
    /// launch may retry.
    public static func runIfNeeded() {
        performMigration(
            legacyDatabaseURL: legacyDatabaseURL,
            targetDatabaseURL: AppGroup.databaseURL,
            defaults: AppGroup.userDefaults
        )
    }

    /// Test seam: same migration logic as `runIfNeeded()`, but with the
    /// legacy source path, App Group destination path, and defaults store
    /// injected. This exists ONLY so unit tests can exercise the migration
    /// against a temporary directory and an isolated `UserDefaults` suite
    /// without touching the developer's real Application Support directory
    /// or the real shared App Group container.
    ///
    /// Production code MUST call `runIfNeeded()`.
    public static func performMigration(
        legacyDatabaseURL legacy: URL,
        targetDatabaseURL target: URL,
        defaults: UserDefaults
    ) {
        if defaults.bool(forKey: migrationFlagKey) {
            return
        }

        let fm = FileManager.default

        // Clean install: nothing to migrate. Mark complete so we never
        // probe the legacy path again.
        guard fm.fileExists(atPath: legacy.path) else {
            defaults.set(true, forKey: migrationFlagKey)
            SanchrLogger.persistence.info("AppGroupMigration v1: no legacy DB, marking complete")
            return
        }

        // Destination already exists. Could be a fresh install that wrote
        // to the App Group container before this migration ever ran, or a
        // previous half-completed run. Either way, do NOT overwrite — mark
        // complete and bail.
        if fm.fileExists(atPath: target.path) {
            defaults.set(true, forKey: migrationFlagKey)
            SanchrLogger.persistence.info("AppGroupMigration v1: destination already exists, skipping copy")
            return
        }

        // Ensure the target directory exists. The App Group container root
        // always exists, but the parent directory of `databaseURL` may not.
        let targetDir = target.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            SanchrLogger.persistence.error("AppGroupMigration v1: failed to create target dir: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Copy the main DB plus its WAL/SHM sidecars. Use copy (not move)
        // so a partial failure leaves the legacy data intact for retry.
        // Sidecars may legitimately be absent — WAL is created on first
        // write, SHM on first reader — so missing sidecars are NOT failures.
        guard copyIfPresent(from: legacy, to: target, required: true) else {
            return
        }
        _ = copyIfPresent(
            from: legacy.appendingPathExtension("wal"),
            to: target.appendingPathExtension("wal"),
            required: false
        )
        _ = copyIfPresent(
            from: legacy.appendingPathExtension("shm"),
            to: target.appendingPathExtension("shm"),
            required: false
        )

        defaults.set(true, forKey: migrationFlagKey)
        SanchrLogger.persistence.info("AppGroupMigration v1: complete")
    }

    /// Test-only accessor for the migration flag key, so tests can assert
    /// flag state on an injected `UserDefaults` suite without duplicating
    /// the literal.
    public static var migrationFlagKeyForTesting: String { migrationFlagKey }

    /// Copy `source` to `destination` if the source exists. Returns `true`
    /// when the post-condition (destination exists OR source legitimately
    /// absent for an optional sidecar) holds. Returns `false` only when a
    /// required copy failed; the caller should abort the migration in that
    /// case so the flag stays unset and we retry next launch.
    private static func copyIfPresent(from source: URL, to destination: URL, required: Bool) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            if required {
                SanchrLogger.persistence.error("AppGroupMigration v1: required source missing at \(source.lastPathComponent, privacy: .public)")
                return false
            }
            return true
        }

        do {
            try fm.copyItem(at: source, to: destination)
            SanchrLogger.persistence.info("AppGroupMigration v1: copied \(source.lastPathComponent, privacy: .public)")
            return true
        } catch {
            SanchrLogger.persistence.error("AppGroupMigration v1: failed to copy \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return !required
        }
    }
}
