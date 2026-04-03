import Foundation
import LibSignalClient

/// File-backed storage for one-time pre-keys used during X3DH key agreement.
///
/// Pre-keys are stored both in-memory (for fast lookups) and on disk so they persist across
/// app launches. Each pre-key is stored as a separate file keyed by its numeric ID.
final class SanchrPreKeyStore: PreKeyStore {

    // MARK: - Properties

    private let userId: String
    private var preKeys: [UInt32: PreKeyRecord] = [:]
    private let queue = DispatchQueue(
        label: "io.sanchr.signal.prekey-store", attributes: .concurrent)
    private let storageDirectory: URL

    /// Tracks the next pre-key ID to avoid collisions when generating new batches.
    private(set) var nextPreKeyId: UInt32 = 1

    // MARK: - Init

    init(userId: String) {
        self.userId = userId

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        self.storageDirectory = base.appendingPathComponent(
            "SignalStore/\(userId)/prekeys", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: storageDirectory, withIntermediateDirectories: true)

        loadAllFromDisk()
    }

    // MARK: - PreKeyStore Protocol

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        var record: PreKeyRecord?
        queue.sync {
            record = preKeys[id]
        }
        guard let found = record else {
            SanchrLogger.crypto.error("Pre-key not found: \(id)")
            throw AppError.decryptionFailed(reason: "Pre-key \(id) not found in local store.")
        }
        return found
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        queue.sync(flags: .barrier) {
            preKeys[id] = record
        }
        let data = Data(record.serialize())
        let fileURL = storageDirectory.appendingPathComponent("\(id).prekey")
        try data.write(to: fileURL, options: .atomic)

        // Advance the next ID tracker
        if id >= nextPreKeyId {
            nextPreKeyId = id + 1
        }
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        queue.sync(flags: .barrier) {
            preKeys.removeValue(forKey: id)
        }
        let fileURL = storageDirectory.appendingPathComponent("\(id).prekey")
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Bulk Operations

    /// Returns the number of pre-keys currently stored.
    var preKeyCount: Int {
        var count = 0
        queue.sync { count = preKeys.count }
        return count
    }

    /// Returns all stored pre-key IDs (for diagnostics or replenishment decisions).
    var storedPreKeyIds: [UInt32] {
        var ids: [UInt32] = []
        queue.sync { ids = Array(preKeys.keys) }
        return ids
    }

    // MARK: - Disk Persistence

    private func loadAllFromDisk() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: nil
            )
        else { return }

        var maxId: UInt32 = 0
        for fileURL in files where fileURL.pathExtension == "prekey" {
            guard
                let idString = fileURL.deletingPathExtension().lastPathComponent.split(
                    separator: "/"
                ).last,
                let id = UInt32(idString)
            else { continue }
            do {
                let data = try Data(contentsOf: fileURL)
                let record = try PreKeyRecord(bytes: [UInt8](data))
                preKeys[id] = record
                if id > maxId { maxId = id }
            } catch {
                SanchrLogger.crypto.warning(
                    "Failed to load pre-key \(id): \(error.localizedDescription)")
            }
        }
        self.nextPreKeyId = maxId + 1
        SanchrLogger.crypto.info(
            "Loaded \(self.preKeys.count) pre-keys from disk, next ID: \(self.nextPreKeyId)")
    }
}
