import Foundation
import SanchrShared

/// Who this user has blocked, kept so that it is there before the first
/// message of a launch is.
///
/// A block on a sealed message can only be applied on this phone. The list
/// it was applied from lived in memory alone, filled from the server several
/// network calls into each launch — after the message stream had been opened.
/// What a blocked person sent while this phone was offline arrives the moment
/// that stream opens, so it arrived before the list did and was delivered.
/// And if the fetch failed, nobody was blocked for the whole session.
///
/// The list is now also stored in the database, and read from there before
/// any message is judged. The server's copy still replaces it whenever it
/// can be fetched.
actor BlockList {
    private let localDatabase: LocalDatabaseProtocol
    private let cache: PrivacySettingsCache
    /// Whether the in-memory list reflects something real: the stored copy,
    /// or the server's.
    private var loaded = false

    init(localDatabase: LocalDatabaseProtocol, cache: PrivacySettingsCache) {
        self.localDatabase = localDatabase
        self.cache = cache
    }

    /// Fills the in-memory list from the stored one, the first time it is
    /// needed. A read that fails is tried again on the next call.
    func ensureLoaded() async {
        guard !loaded else { return }
        do {
            let stored = try await localDatabase.fetchBlockedUserIds()
            // The server's list may have landed while the read was out; it
            // is the newer of the two.
            guard !loaded else { return }
            cache.update(blockList: stored)
            loaded = true
        } catch {
            SanchrLogger.settings.error("Stored block list could not be read: \(error.localizedDescription)")
        }
    }

    /// The server's list, which replaces what is held and what is stored.
    func replace(withServerList userIds: Set<String>) async {
        cache.update(blockList: userIds)
        loaded = true
        do {
            try await localDatabase.replaceBlockedUserIds(userIds)
        } catch {
            SanchrLogger.settings.error("Block list could not be stored: \(error.localizedDescription)")
        }
    }

    /// One block or unblock the server has just accepted.
    func setBlocked(_ userId: String, _ blocked: Bool) async {
        await ensureLoaded()
        cache.setBlocked(userId, blocked)
        do {
            try await localDatabase.setUserBlocked(userId, blocked: blocked)
        } catch {
            SanchrLogger.settings.error("Block change could not be stored: \(error.localizedDescription)")
        }
    }
}
