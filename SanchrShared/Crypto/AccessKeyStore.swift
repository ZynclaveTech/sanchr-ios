import Foundation

public protocol AccessKeyStoreProtocol: AnyObject, Sendable {
    /// Store a new entry. `createdAt` and `lastAccessedAt` are both stamped
    /// to the current time.
    func store(
        mediaId: String,
        accessKey: Data,
        conversationId: String,
        kind: AccessKeyEntry.Kind
    ) async throws

    /// Retrieve the raw key bytes if the entry exists AND is not expired.
    /// Does NOT bump `lastAccessedAt` — use `getAndTouch` on decrypt paths.
    func retrieve(mediaId: String) async throws -> Data?

    /// Retrieve the full entry, including metadata. Only used by tests and
    /// introspection code; production decrypt paths use `getAndTouch`.
    func retrieveEntry(mediaId: String) async throws -> AccessKeyEntry?

    /// Bump `lastAccessedAt` to `now()`. A separate method from `retrieve`
    /// so callers can decide whether the access was "successful" (decrypt
    /// worked) before extending the TTL.
    func touch(mediaId: String) async throws

    /// Convenience `retrieve + touch` — the canonical entry point for
    /// decrypt paths. Returns `nil` if the entry is missing or expired.
    ///
    /// NOT transactionally atomic: issues a read then a separate write.
    /// Under concurrent `purgeExpired()` / `deleteAccessKeyEntry()` the
    /// touch may silently no-op, but the returned key is always a valid
    /// snapshot at the time of the read. Safe for the sliding-TTL model
    /// because any race outcome preserves the security property
    /// (`lastAccessedAt` only ever moves forward or the entry vanishes).
    func getAndTouch(mediaId: String) async throws -> Data?

    /// Delete every entry whose sliding TTL has elapsed. Returns the count
    /// of purged entries.
    func purgeExpired() async throws -> Int

    /// Wipe the whole store. Used on sign-out or vault reset.
    func deleteAll() async throws
}

// MARK: - HKDF v2 Migration

extension AccessKeyStoreProtocol {
    private static var hkdfMigrationKey: String { "sanchr.accesskey.hkdf_v2_migrated" }

    /// Purges all AccessK entries derived under the pre-v2 HKDF parameters.
    /// Called once on first launch after the derivation fix. Media can be
    /// re-requested from sender via the ratchet channel if needed.
    public func migrateHKDFv2IfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.hkdfMigrationKey) else { return }

        do {
            try await deleteAll()
            SanchrLogger.crypto.info("HKDF v2 migration: purged all stale AccessK entries")
        } catch {
            SanchrLogger.crypto.error("HKDF v2 migration failed: \(error)")
        }

        UserDefaults.standard.set(true, forKey: Self.hkdfMigrationKey)
    }
}

public final class AccessKeyStore: AccessKeyStoreProtocol, @unchecked Sendable {
    public static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    private let localDatabase: LocalDatabaseProtocol
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        localDatabase: LocalDatabaseProtocol,
        ttl: TimeInterval = AccessKeyStore.defaultTTL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.localDatabase = localDatabase
        self.ttl = ttl
        self.clock = clock
    }

    public func store(
        mediaId: String,
        accessKey: Data,
        conversationId: String,
        kind: AccessKeyEntry.Kind
    ) async throws {
        let now = clock()
        let entry = AccessKeyEntry(
            mediaId: mediaId,
            accessKey: accessKey,
            conversationId: conversationId,
            kind: kind,
            createdAt: now,
            lastAccessedAt: now
        )
        try await localDatabase.saveAccessKeyEntry(entry)
    }

    public func retrieve(mediaId: String) async throws -> Data? {
        guard let entry = try await retrieveEntry(mediaId: mediaId) else {
            return nil
        }
        return entry.accessKey
    }

    public func retrieveEntry(mediaId: String) async throws -> AccessKeyEntry? {
        guard let entry = try await localDatabase.fetchAccessKeyEntry(mediaId: mediaId) else {
            return nil
        }
        // Sliding expiry check: if both anchors are older than ttl, treat
        // as absent and let a background purge reap it.
        let anchor = max(entry.createdAt, entry.lastAccessedAt)
        if clock().timeIntervalSince(anchor) > ttl {
            return nil
        }
        return entry
    }

    public func touch(mediaId: String) async throws {
        try await localDatabase.updateAccessKeyEntryLastAccessed(
            mediaId: mediaId,
            lastAccessedAt: clock()
        )
    }

    public func getAndTouch(mediaId: String) async throws -> Data? {
        guard let entry = try await retrieveEntry(mediaId: mediaId) else {
            return nil
        }
        try await touch(mediaId: mediaId)
        return entry.accessKey
    }

    public func purgeExpired() async throws -> Int {
        let cutoff = clock().addingTimeInterval(-ttl)
        return try await localDatabase.purgeAccessKeyEntries(olderThan: cutoff)
    }

    public func deleteAll() async throws {
        try await localDatabase.deleteAllAccessKeyEntries()
    }
}
