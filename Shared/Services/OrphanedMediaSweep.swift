import Foundation
import SanchrShared

/// Removes decrypted photos and videos whose message is no longer on this
/// phone.
///
/// Deleting a message or a chat removes its media now. It did not always:
/// Delete Message left the file, and "Delete Conversation" deleted nothing at
/// all. Nothing in the database points at those files any more, so nothing
/// that works from the database will find them. This works from the files.
///
/// It only removes what it is sure of. This directory is where received
/// media lives, not a cache that can be refilled — the server does not keep
/// media for ever — so a file is left alone unless its name gives a message
/// id, no message has that id, and it is old enough not to belong to
/// something still being sent or saved.
enum OrphanedMediaSweep {

    /// A message's file is written before its row in places, and a sent
    /// message's id changes when the server accepts it. An hour is far longer
    /// than either takes.
    static let minimumAge: TimeInterval = 60 * 60

    /// The message a stored file belongs to, read back from its name, or nil
    /// if the name does not say.
    ///
    /// `<id>.jpg`, `<id>#2.mp4`. Only a name whose id is the UUID every
    /// message id in practice is: a hashed name (see `MediaCacheFile.safeId`)
    /// does not give its id back, and anything else is some other file. Those
    /// are answered with nil rather than a guess — the caller is deciding
    /// what to delete.
    static func messageId(fromFileName name: String) -> String? {
        let end = name.firstIndex(where: { $0 == "." || $0 == "#" }) ?? name.endIndex
        let base = String(name[..<end])
        return UUID(uuidString: base) != nil && base.count == 36 ? base : nil
    }

    /// - Parameter existingIds: which of the given message ids are messages
    ///   on this phone. If it throws, nothing is removed.
    /// - Returns: the message ids whose files were removed.
    @discardableResult
    static func sweep(
        directory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        existingIds: ([String]) async throws -> Set<String>
    ) async -> Set<String> {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return [] }

        var candidates: [(id: String, url: URL)] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= minimumAge,
                  let id = messageId(fromFileName: url.lastPathComponent)
            else { continue }
            candidates.append((id, url))
        }
        guard !candidates.isEmpty else { return [] }

        let existing: Set<String>
        do {
            existing = try await existingIds(Array(Set(candidates.map(\.id))))
        } catch {
            SanchrLogger.chat.error("Orphaned media sweep skipped: \(error.localizedDescription)")
            return []
        }

        var removed = Set<String>()
        for candidate in candidates where !existing.contains(candidate.id) {
            if (try? fileManager.removeItem(at: candidate.url)) != nil {
                removed.insert(candidate.id)
            }
        }
        if !removed.isEmpty {
            SanchrLogger.chat.info("Orphaned media sweep removed files for \(removed.count) message(s)")
        }
        return removed
    }
}
