import Foundation
import LibSignalClient

/// File-backed sender key storage for Signal Protocol group messaging.
///
/// Sender keys enable efficient group encryption where each member maintains a single
/// ratcheting chain rather than pairwise sessions with every group member.
public final class SanchrSenderKeyStore: SenderKeyStore {

    // MARK: - Properties

    private let userId: String
    private var senderKeys: [SenderKeyStoreKey: SenderKeyRecord] = [:]
    private let queue = DispatchQueue(
        label: "io.sanchr.signal.sender-key-store", attributes: .concurrent)
    private let storageDirectory: URL

    // MARK: - Init

    public init(userId: String) {
        self.userId = userId

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        self.storageDirectory = base.appendingPathComponent(
            "SignalStore/\(userId)/senderkeys", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: storageDirectory, withIntermediateDirectories: true)

        loadAllFromDisk()
    }

    // MARK: - SenderKeyStore Protocol

    public func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        let storeKey = SenderKeyStoreKey(sender: sender, distributionId: distributionId)
        queue.sync(flags: .barrier) {
            senderKeys[storeKey] = record
        }
        let data = Data(record.serialize())
        let fileURL = fileURL(for: storeKey)
        try data.write(to: fileURL, options: .atomic)
    }

    public func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        let storeKey = SenderKeyStoreKey(sender: sender, distributionId: distributionId)
        var record: SenderKeyRecord?
        queue.sync {
            record = senderKeys[storeKey]
        }
        return record
    }

    // MARK: - Composite Key

    /// Hashable composite key combining sender address and distribution ID.
    private struct SenderKeyStoreKey: Hashable {
        let senderName: String
        let senderDeviceId: UInt32
        let distributionId: UUID

        init(sender: ProtocolAddress, distributionId: UUID) {
            self.senderName = sender.name
            self.senderDeviceId = sender.deviceId
            self.distributionId = distributionId
        }

        var fileName: String {
            let safeName = senderName.replacingOccurrences(of: "/", with: "_")
            return "\(safeName).\(senderDeviceId).\(distributionId.uuidString).senderkey"
        }
    }

    // MARK: - Persistence Helpers

    private func fileURL(for key: SenderKeyStoreKey) -> URL {
        storageDirectory.appendingPathComponent(key.fileName)
    }

    private func loadAllFromDisk() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: nil
            )
        else { return }

        var loadedCount = 0
        for fileURL in files where fileURL.pathExtension == "senderkey" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            // Format: senderName.deviceId.uuid.senderkey
            // We need to parse from the end since senderName can contain dots
            let components = filename.split(separator: ".")
            guard components.count >= 3 else { continue }

            // Last component is the UUID (36 chars), second-to-last is deviceId
            let uuidString = String(components.last!)
            let deviceIdString = String(components[components.count - 2])

            guard let distributionId = UUID(uuidString: uuidString),
                let deviceId = UInt32(deviceIdString)
            else { continue }

            let senderName = components.dropLast(2).joined(separator: ".")

            do {
                let data = try Data(contentsOf: fileURL)
                let record = try SenderKeyRecord(bytes: [UInt8](data))
                let address = try ProtocolAddress(name: senderName, deviceId: deviceId)
                let storeKey = SenderKeyStoreKey(sender: address, distributionId: distributionId)
                senderKeys[storeKey] = record
                loadedCount += 1
            } catch {
                SanchrLogger.crypto.warning(
                    "Failed to load sender key \(filename): \(error.localizedDescription)")
            }
        }
        if loadedCount > 0 {
            SanchrLogger.crypto.info("Loaded \(loadedCount) sender keys from disk")
        }
    }
}
