import Foundation

/// Persisted local configuration for remote encrypted backups.
public struct BackupConfiguration: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let lineageId: String
    public let formatVersion: Int32
    public let recoveryKeyConfirmedAt: Date
    public let lastBackupAt: Date?
    public let lastBackupContentHash: String?

    public init(
        isEnabled: Bool,
        lineageId: String,
        formatVersion: Int32,
        recoveryKeyConfirmedAt: Date,
        lastBackupAt: Date? = nil,
        lastBackupContentHash: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.lineageId = lineageId
        self.formatVersion = formatVersion
        self.recoveryKeyConfirmedAt = recoveryKeyConfirmedAt
        self.lastBackupAt = lastBackupAt
        self.lastBackupContentHash = lastBackupContentHash
    }
}
