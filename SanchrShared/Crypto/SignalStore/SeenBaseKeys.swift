import Foundation

/// The first messages already accepted against a long-lived Kyber pre-key.
///
/// A one-time pre-key is spent by the first message sent to it, which is what
/// stops that message being replayed: the second time, the key is gone. The
/// Kyber pre-key this app publishes is not one-time — it stays until it is
/// rotated — and the server hands out bundles with no one-time key at all
/// once a user's supply runs out. A first message sent to such a bundle has
/// nothing spent behind it. While the session it started is still held, the
/// replay is recognised against that session; once it is not, the only record
/// that the message was ever seen is the one kept here.
///
/// Each first message has its own base key, so remembering which base keys
/// have been used with which pre-keys is enough. They are public values.
///
/// Three things this is careful about, because each is a way for the record
/// to stop meaning what it says:
///
/// - An entry is kept for as long as the Kyber pre-key it belongs to is still
///   held, and dropped only when that key is gone. Forgetting the oldest
///   entries to make room would let anyone able to start sessions push a
///   live entry out and then replay the message it stood for.
/// - When a key's entries reach the limit, new first messages to it are
///   refused. That is the point at which the key should have been rotated.
/// - A record that exists but cannot be read is not treated as empty. It is
///   read fresh on every use, so another process's additions are seen, and a
///   failure to read or save it refuses the message.
public final class SeenBaseKeys: @unchecked Sendable {
    public enum RecordError: Error, Equatable {
        /// The record exists and could not be read or understood.
        case unreadable
        /// This pre-key has accepted as many first messages as will be remembered.
        case full
    }

    private let fileURL: URL
    private let limitPerKey: Int
    private let lock = NSLock()

    public init(fileURL: URL, limitPerKey: Int = 20_000) {
        self.fileURL = fileURL
        self.limitPerKey = max(1, limitPerKey)
    }

    /// Records that `baseKey` was used with this pair of pre-keys.
    ///
    /// - Parameter isHeld: whether a Kyber pre-key with this id is still in
    ///   the store. Entries for keys that are not are dropped here.
    /// - Returns: false if it already had been used, in which case nothing changes.
    /// - Throws: `RecordError`, or the error from saving. A base key that is
    ///   not durably remembered would be accepted again after a restart, so
    ///   the message is refused rather than read on a promise that cannot be
    ///   kept.
    public func insert(
        kyberPreKeyId: UInt32,
        signedPreKeyId: UInt32,
        baseKey: Data,
        isHeld: (UInt32) -> Bool
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let prefix = "\(kyberPreKeyId):"
        let entry = "\(prefix)\(signedPreKeyId):\(baseKey.base64EncodedString())"
        var entries = try load().filter { saved in
            // The id being recorded is in use by definition.
            guard let id = Self.kyberPreKeyId(of: saved) else { return false }
            return id == kyberPreKeyId || isHeld(id)
        }
        guard !entries.contains(entry) else { return false }
        guard entries.lazy.filter({ $0.hasPrefix(prefix) }).count < limitPerKey else { throw RecordError.full }

        entries.append(entry)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        return true
    }

    /// The saved entries. No file is an empty record; a file that cannot be
    /// read or decoded is an error, never an empty record.
    private func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([String].self, from: data)
        else { throw RecordError.unreadable }
        return saved
    }

    private static func kyberPreKeyId(of entry: String) -> UInt32? {
        entry.split(separator: ":", maxSplits: 1).first.flatMap { UInt32($0) }
    }
}
