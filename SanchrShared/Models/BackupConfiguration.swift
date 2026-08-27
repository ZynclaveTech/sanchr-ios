import Foundation

/// Where an encrypted backup archive is written.
///
/// Both destinations receive the same recovery-key-encrypted archive; they
/// differ in scope and in who can observe that a backup exists at all:
/// - `sanchrCloud` uploads chats only to Sanchr's servers (ciphertext; the
///   server knows a backup exists but cannot read it).
/// - `iCloud` writes chats *and media* to the user's own iCloud container.
///   Sanchr's servers are never contacted about it — the app cannot see, store,
///   or track iCloud backups even in principle.
public enum BackupDestination: String, Codable, CaseIterable, Sendable {
    case sanchrCloud = "sanchr_cloud"
    case iCloud = "icloud"
}

/// How often an automatic backup runs. Automatic backups fire opportunistically
/// (app background / periodic sync) once the interval has elapsed; `off` means
/// manual "Back up now" only.
public enum BackupFrequency: String, Codable, CaseIterable, Sendable {
    case off
    case daily
    case weekly

    /// Minimum seconds between automatic backups, nil when disabled.
    public var minimumInterval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }
}

/// Persisted local configuration for remote encrypted backups.
public struct BackupConfiguration: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let lineageId: String
    public let formatVersion: Int32
    public let recoveryKeyConfirmedAt: Date
    public let lastBackupAt: Date?
    public let lastBackupContentHash: String?
    /// Enabled destinations. Defaults to Sanchr cloud alone, which is what every
    /// configuration stored before destinations existed meant.
    public let destinations: Set<BackupDestination>
    /// Automatic backup cadence. Configurations stored before this field existed
    /// behaved as opportunistic-daily, so that is the decode default.
    public let frequency: BackupFrequency
    /// Restrict media upload (iCloud scope) to Wi-Fi.
    public let wifiOnlyMedia: Bool
    /// Last successful backup per destination; `lastBackupAt` remains the
    /// most-recent of any destination for backward compatibility.
    public let lastICloudBackupAt: Date?

    public init(
        isEnabled: Bool,
        lineageId: String,
        formatVersion: Int32,
        recoveryKeyConfirmedAt: Date,
        lastBackupAt: Date? = nil,
        lastBackupContentHash: String? = nil,
        destinations: Set<BackupDestination> = [.sanchrCloud],
        frequency: BackupFrequency = .daily,
        wifiOnlyMedia: Bool = true,
        lastICloudBackupAt: Date? = nil
    ) {
        self.isEnabled = isEnabled
        self.lineageId = lineageId
        self.formatVersion = formatVersion
        self.recoveryKeyConfirmedAt = recoveryKeyConfirmedAt
        self.lastBackupAt = lastBackupAt
        self.lastBackupContentHash = lastBackupContentHash
        self.destinations = destinations
        self.frequency = frequency
        self.wifiOnlyMedia = wifiOnlyMedia
        self.lastICloudBackupAt = lastICloudBackupAt
    }

    /// Backward-compatible decoding: configurations persisted before the
    /// destination/frequency fields existed decode with the defaults above
    /// rather than failing, so enabling the new options never invalidates an
    /// existing recovery-key setup.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        lineageId = try c.decode(String.self, forKey: .lineageId)
        formatVersion = try c.decode(Int32.self, forKey: .formatVersion)
        recoveryKeyConfirmedAt = try c.decode(Date.self, forKey: .recoveryKeyConfirmedAt)
        lastBackupAt = try c.decodeIfPresent(Date.self, forKey: .lastBackupAt)
        lastBackupContentHash = try c.decodeIfPresent(String.self, forKey: .lastBackupContentHash)
        destinations =
            try c.decodeIfPresent(Set<BackupDestination>.self, forKey: .destinations)
            ?? [.sanchrCloud]
        frequency = try c.decodeIfPresent(BackupFrequency.self, forKey: .frequency) ?? .daily
        wifiOnlyMedia = try c.decodeIfPresent(Bool.self, forKey: .wifiOnlyMedia) ?? true
        lastICloudBackupAt = try c.decodeIfPresent(Date.self, forKey: .lastICloudBackupAt)
    }

    /// Copy with updated backup preferences, preserving the recovery-key
    /// identity fields (lineage, format, confirmation) untouched.
    public func updatingPreferences(
        destinations: Set<BackupDestination>? = nil,
        frequency: BackupFrequency? = nil,
        wifiOnlyMedia: Bool? = nil
    ) -> BackupConfiguration {
        BackupConfiguration(
            isEnabled: isEnabled,
            lineageId: lineageId,
            formatVersion: formatVersion,
            recoveryKeyConfirmedAt: recoveryKeyConfirmedAt,
            lastBackupAt: lastBackupAt,
            lastBackupContentHash: lastBackupContentHash,
            destinations: destinations ?? self.destinations,
            frequency: frequency ?? self.frequency,
            wifiOnlyMedia: wifiOnlyMedia ?? self.wifiOnlyMedia,
            lastICloudBackupAt: lastICloudBackupAt
        )
    }
}
