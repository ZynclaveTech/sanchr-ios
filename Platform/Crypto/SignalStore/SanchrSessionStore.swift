import Foundation
import LibSignalClient

/// File-backed session storage for the Signal Protocol Double Ratchet.
///
/// Sessions are keyed by `ProtocolAddress` (name.deviceId) and stored as individual files
/// in the app's Application Support directory. An in-memory cache avoids redundant disk reads.
final class SanchrSessionStore: SessionStore {

    // MARK: - Properties

    private let userId: String
    private var sessions: [ProtocolAddress: SessionRecord] = [:]
    private let queue = DispatchQueue(
        label: "io.sanchr.signal.session-store", attributes: .concurrent)
    private let storageDirectory: URL

    // MARK: - Init

    init(userId: String) {
        self.userId = userId

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        self.storageDirectory = base.appendingPathComponent(
            "SignalStore/\(userId)/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: storageDirectory, withIntermediateDirectories: true)

        loadAllFromDisk()
    }

    // MARK: - SessionStore Protocol

    func loadSession(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> SessionRecord? {
        var record: SessionRecord?
        queue.sync {
            record = sessions[address]
        }
        return record
    }

    func storeSession(
        _ record: SessionRecord,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws {
        queue.sync(flags: .barrier) {
            sessions[address] = record
        }
        let data = Data(record.serialize())
        let fileURL = fileURL(for: address)
        try data.write(to: fileURL, options: .atomic)
    }

    func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        return try addresses.map { address in
            guard let record = try loadSession(for: address, context: context) else {
                throw SignalError.sessionNotFound("\(address)")
            }
            return record
        }
    }

    // MARK: - Session Queries

    /// Returns `true` if a session exists for the given address.
    func hasSession(for address: ProtocolAddress) -> Bool {
        var exists = false
        queue.sync { exists = sessions[address] != nil }
        return exists
    }

    /// Removes the session for a given address (used for session reset / identity change).
    func deleteSession(for address: ProtocolAddress) throws {
        queue.sync(flags: .barrier) {
            sessions.removeValue(forKey: address)
        }
        let fileURL = fileURL(for: address)
        try? FileManager.default.removeItem(at: fileURL)
        SanchrLogger.crypto.info("Deleted session for \(address.name).\(address.deviceId)")
    }

    /// Removes all sessions for a given user (across all their devices).
    func deleteAllSessions(for name: String) throws {
        var toRemove: [ProtocolAddress] = []
        queue.sync {
            toRemove = sessions.keys.filter { $0.name == name }
        }
        for address in toRemove {
            try deleteSession(for: address)
        }
    }

    // MARK: - Persistence Helpers

    private func fileURL(for address: ProtocolAddress) -> URL {
        let safeName = address.name.replacingOccurrences(of: "/", with: "_")
        return storageDirectory.appendingPathComponent("\(safeName).\(address.deviceId).session")
    }

    private func loadAllFromDisk() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: nil
            )
        else { return }

        var loadedCount = 0
        for fileURL in files where fileURL.pathExtension == "session" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            let components = filename.split(separator: ".")
            guard components.count >= 2,
                let deviceId = UInt32(components.last!)
            else { continue }
            let name = components.dropLast().joined(separator: ".")
            do {
                let data = try Data(contentsOf: fileURL)
                let record = try SessionRecord(bytes: [UInt8](data))
                let address = try ProtocolAddress(name: name, deviceId: deviceId)
                sessions[address] = record
                loadedCount += 1
            } catch {
                SanchrLogger.crypto.warning(
                    "Failed to load session \(filename): \(error.localizedDescription)")
            }
        }
        SanchrLogger.crypto.info("Loaded \(loadedCount) sessions from disk")
    }
}
