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
/// Bounded: the oldest are forgotten first. A base key that old was used with
/// pre-keys that have almost certainly been rotated since, and an unbounded
/// file that anyone can add to by sending a message is its own problem.
public final class SeenBaseKeys: @unchecked Sendable {
    private let fileURL: URL
    private let limit: Int
    private let lock = NSLock()
    private var order: [String] = []
    private var members: Set<String> = []

    public init(fileURL: URL, limit: Int = 4096) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            order = Array(saved.suffix(self.limit))
            members = Set(order)
        }
    }

    /// Records that `baseKey` was used with this pair of pre-keys.
    ///
    /// - Returns: false if it already had been, in which case nothing changes.
    /// - Throws: if the record cannot be saved. A base key that is not
    ///   durably remembered would be accepted again after a restart, so the
    ///   message is refused rather than read on a promise that cannot be kept.
    public func insert(kyberPreKeyId: UInt32, signedPreKeyId: UInt32, baseKey: Data) throws -> Bool {
        let entry = "\(kyberPreKeyId):\(signedPreKeyId):\(baseKey.base64EncodedString())"
        lock.lock()
        defer { lock.unlock() }
        guard !members.contains(entry) else { return false }

        var updated = order
        updated.append(entry)
        if updated.count > limit { updated.removeFirst(updated.count - limit) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)

        order = updated
        members = Set(updated)
        return true
    }
}
