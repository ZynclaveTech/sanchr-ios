import Foundation
import SanchrShared

/// A backup found in the user's iCloud container.
struct ICloudBackupEntry: Equatable, Sendable {
    let url: URL
    let lineageId: String
    let modifiedAt: Date
    let byteSize: Int64
}

protocol ICloudBackupStoreProtocol: Sendable {
    /// Whether the iCloud container is reachable — the entitlement is granted
    /// and the device is signed into iCloud with iCloud Drive enabled.
    func isAvailable() -> Bool
    /// Write one encrypted archive (ciphertext + its opaque metadata sidecar)
    /// for a lineage, replacing any previous backup of the same lineage.
    func writeBackup(ciphertext: Data, metadataJSON: Data, lineageId: String) throws -> Date
    /// The most recently modified backup in the container, if any.
    func latestBackup() throws -> ICloudBackupEntry?
    /// Read a backup's ciphertext and metadata sidecar.
    func readBackup(_ entry: ICloudBackupEntry) throws -> (ciphertext: Data, metadataJSON: Data)
    /// Remove every backup file this app wrote to the container.
    func deleteAllBackups() throws
}

/// Writes recovery-key-encrypted backup archives into the app's iCloud
/// Documents container.
///
/// Privacy property this type exists to uphold: nothing here talks to Sanchr's
/// servers. The archive arrives already encrypted (the same AES+HMAC envelope
/// the Sanchr-cloud path uploads), is written to the user's own iCloud storage,
/// and its existence is never reported anywhere — Sanchr cannot see, store, or
/// track iCloud backups even in principle.
final class ICloudBackupStore: ICloudBackupStoreProtocol, @unchecked Sendable {
    static let containerIdentifier = "iCloud.com.sanchr.app"
    private static let backupsDirectory = "Backups"
    private static let archiveExtension = "sanchrbackup"
    private static let metadataExtension = "sanchrbackupmeta"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The container's Backups directory, or nil when iCloud is unavailable.
    ///
    /// `url(forUbiquityContainerIdentifier:)` performs file-system work, so
    /// callers on the main thread should treat availability as advisory and do
    /// real IO off the main actor (the backup pipeline already runs in a task).
    private func backupsDirectoryURL() -> URL? {
        guard
            let container = fileManager.url(
                forUbiquityContainerIdentifier: Self.containerIdentifier)
        else { return nil }
        return container.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.backupsDirectory, isDirectory: true)
    }

    func isAvailable() -> Bool {
        backupsDirectoryURL() != nil
    }

    func writeBackup(ciphertext: Data, metadataJSON: Data, lineageId: String) throws -> Date {
        guard let directory = backupsDirectoryURL() else {
            throw AppError.backupFailed(
                reason:
                    "iCloud is not available. Sign in to iCloud and enable iCloud Drive to back up there."
            )
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let archiveURL = directory.appendingPathComponent(
            "\(lineageId).\(Self.archiveExtension)")
        let metadataURL = directory.appendingPathComponent(
            "\(lineageId).\(Self.metadataExtension)")

        // Coordinated writes keep us correct against the iCloud daemon syncing
        // the same files concurrently.
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: archiveURL, options: .forReplacing, error: &coordinatorError
        ) { url in
            do {
                try ciphertext.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if writeError == nil, coordinatorError == nil {
            coordinator.coordinate(
                writingItemAt: metadataURL, options: .forReplacing, error: &coordinatorError
            ) { url in
                do {
                    try metadataJSON.write(to: url, options: .atomic)
                } catch {
                    writeError = error
                }
            }
        }
        if let error = writeError ?? coordinatorError {
            throw AppError.backupFailed(
                reason: "Couldn't write the backup to iCloud: \(error.localizedDescription)")
        }
        return Date()
    }

    func latestBackup() throws -> ICloudBackupEntry? {
        guard let directory = backupsDirectoryURL(),
            fileManager.fileExists(atPath: directory.path)
        else { return nil }

        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let archives = contents.filter { $0.pathExtension == Self.archiveExtension }
        let entries: [ICloudBackupEntry] = archives.compactMap { url in
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey,
            ])
            return ICloudBackupEntry(
                url: url,
                lineageId: url.deletingPathExtension().lastPathComponent,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                byteSize: Int64(values?.fileSize ?? 0)
            )
        }
        return entries.max(by: { $0.modifiedAt < $1.modifiedAt })
    }

    func readBackup(_ entry: ICloudBackupEntry) throws -> (ciphertext: Data, metadataJSON: Data) {
        let metadataURL = entry.url.deletingPathExtension()
            .appendingPathExtension(Self.metadataExtension)
        var coordinatorError: NSError?
        var ciphertext = Data()
        var metadataJSON = Data()
        var readError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: entry.url, options: [], error: &coordinatorError
        ) { url in
            do {
                ciphertext = try Data(contentsOf: url)
            } catch {
                readError = error
            }
        }
        if readError == nil, coordinatorError == nil {
            coordinator.coordinate(
                readingItemAt: metadataURL, options: [], error: &coordinatorError
            ) { url in
                do {
                    metadataJSON = try Data(contentsOf: url)
                } catch {
                    readError = error
                }
            }
        }
        if let error = readError ?? coordinatorError {
            throw AppError.backupFailed(
                reason: "Couldn't read the iCloud backup: \(error.localizedDescription)")
        }
        return (ciphertext, metadataJSON)
    }

    func deleteAllBackups() throws {
        guard let directory = backupsDirectoryURL(),
            fileManager.fileExists(atPath: directory.path)
        else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for url in contents
        where [Self.archiveExtension, Self.metadataExtension].contains(url.pathExtension) {
            try? fileManager.removeItem(at: url)
        }
    }
}
