import Foundation

// MARK: - UserDefaults Keys

private enum SyncStateKeys {
    static let lastSyncTimestamp = "io.sanchr.sync.lastSyncTimestamp"
    static let pendingMessageCount = "io.sanchr.sync.pendingMessageCount"
}

/// Tracks sync state across the app.
/// Observed by views to display syncing indicators and trigger refreshes.
@Observable
final class SyncState: @unchecked Sendable {

    // MARK: - Published State

    /// Timestamp of the last successful sync.
    var lastSyncTimestamp: Date?

    /// Whether a sync operation is currently in progress.
    var isSyncing: Bool = false

    /// Number of new messages received in the most recent sync.
    var pendingMessageCount: Int = 0

    /// The error from the most recent failed sync, if any.
    var syncError: Error?

    // MARK: - Computed

    /// Time interval since the last successful sync, or nil if never synced.
    var timeSinceLastSync: TimeInterval? {
        guard let last = lastSyncTimestamp else { return nil }
        return Date().timeIntervalSince(last)
    }

    /// Whether a sync is needed (more than 5 minutes since last sync, or never synced).
    var needsSync: Bool {
        guard let interval = timeSinceLastSync else { return true }
        return interval > 300
    }

    // MARK: - State Mutations

    /// Mark the beginning of a sync operation.
    func markSyncStarted() {
        isSyncing = true
        syncError = nil
    }

    /// Mark a sync as successfully completed.
    /// - Parameter messageCount: The number of new messages received during sync.
    func markSyncCompleted(messageCount: Int) {
        isSyncing = false
        lastSyncTimestamp = Date()
        pendingMessageCount = messageCount
        syncError = nil
        save()
    }

    /// Mark a sync as failed.
    /// - Parameter error: The error that caused the sync to fail.
    func markSyncFailed(error: Error) {
        isSyncing = false
        syncError = error
    }

    // MARK: - Persistence

    /// Persists the current sync state to UserDefaults.
    func save() {
        let defaults = UserDefaults.standard
        if let timestamp = lastSyncTimestamp {
            defaults.set(timestamp.timeIntervalSince1970, forKey: SyncStateKeys.lastSyncTimestamp)
        }
        defaults.set(pendingMessageCount, forKey: SyncStateKeys.pendingMessageCount)
    }

    /// Loads persisted sync state from UserDefaults.
    /// - Returns: A `SyncState` instance populated with previously saved values.
    static func load() -> SyncState {
        let state = SyncState()
        let defaults = UserDefaults.standard

        let storedTimestamp = defaults.double(forKey: SyncStateKeys.lastSyncTimestamp)
        if storedTimestamp > 0 {
            state.lastSyncTimestamp = Date(timeIntervalSince1970: storedTimestamp)
        }

        state.pendingMessageCount = defaults.integer(forKey: SyncStateKeys.pendingMessageCount)
        return state
    }
}
