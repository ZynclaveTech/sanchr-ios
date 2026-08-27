import CommonCrypto
import CryptoKit
import Foundation
import Security
import SanchrShared

struct BackupUploadOutcome: Sendable {
    let backupDate: Date
    let contentHash: String
    /// When the archive was also written to the user's iCloud container; nil
    /// when iCloud was not an enabled destination or the write was skipped.
    let iCloudBackupDate: Date?

    init(backupDate: Date, contentHash: String, iCloudBackupDate: Date? = nil) {
        self.backupDate = backupDate
        self.contentHash = contentHash
        self.iCloudBackupDate = iCloudBackupDate
    }
}

struct BackupRestoreOutcome: Sendable {
    let lineageID: String
    let formatVersion: Int32
    let backupDate: Date?
    let contentHash: String?
}

struct BackupListEntry: Identifiable, Sendable {
    let id: String          // backup_id from proto
    let committedAt: Date
    let byteSize: Int64
    let messageCount: Int?  // from opaqueMetadata JSON counts.messages; nil if unparseable
}

/// A restorable backup discovered in the user's iCloud container.
struct ICloudRestoreCandidate: Sendable {
    let entry: ICloudBackupEntry
    let messageCount: Int?
    let exportedAt: Date?
}

private struct BackupOpaqueMetadata: Codable, Sendable {
    let formatVersion: Int32
    let ivBase64: String
    let hmacBase64: String
    let exportedAtMs: Int64
    let contentHash: String
    let platform: String
    let appVersion: String
    let counts: BackupArchiveRecordCounts
}

protocol BackupArchiveServiceProtocol: Sendable {
    func performBackup(
        configuration: BackupConfiguration,
        material: DerivedBackupMaterial,
        currentUserId: String?,
        force: Bool
    ) async throws -> BackupUploadOutcome?
    func restoreLatestBackup(
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome
    func deleteRemoteBackups(lineageID: String?) async throws
    func listBackups() async throws -> [BackupListEntry]
    func restoreBackup(
        backupId: String,
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome
    /// The newest backup in the user's iCloud container, or nil when iCloud is
    /// unavailable or holds none. Never contacts Sanchr's servers.
    func latestICloudBackup() async -> ICloudRestoreCandidate?
    /// Restore the newest iCloud backup: verify, decrypt, load into the local
    /// database, and best-effort restore its staged media into the cache.
    func restoreLatestICloudBackup(
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome
}

actor BackupArchiveService: BackupArchiveServiceProtocol {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let deviceSecretProvider: DeviceSecretProviderProtocol
    private let session: URLSession
    private let iCloudStore: ICloudBackupStoreProtocol
    private let networkMonitor: NetworkMonitorProtocol?

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        deviceSecretProvider: DeviceSecretProviderProtocol,
        session: URLSession = .shared,
        iCloudStore: ICloudBackupStoreProtocol = ICloudBackupStore(),
        networkMonitor: NetworkMonitorProtocol? = nil
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.deviceSecretProvider = deviceSecretProvider
        self.session = session
        self.iCloudStore = iCloudStore
        self.networkMonitor = networkMonitor
    }

    func performBackup(
        configuration: BackupConfiguration,
        material: DerivedBackupMaterial,
        currentUserId: String?,
        force: Bool
    ) async throws -> BackupUploadOutcome? {
        guard currentUserId?.isEmpty == false else {
            throw AppError.backupFailed(reason: "You must be signed in before creating a backup.")
        }
        guard let aesKey = material.aesKey, let hmacKey = material.hmacKey else {
            throw AppError.backupFailed(reason: "Backup keys are unavailable for this account.")
        }

        let fingerprint = try deviceSecretProvider.backupFingerprint()
        let snapshot = try await localDatabase.exportBackupSnapshot(
            currentUserId: currentUserId,
            fingerprint: fingerprint
        )
        let archiveData = try BackupArchiveSerializer.serialize(snapshot)
        let contentHash = Self.sha256Hex(archiveData)

        if !force,
           configuration.lastBackupContentHash == contentHash {
            return nil
        }

        if !force {
            // Automatic runs honour the user's frequency: Off means manual
            // "Back Up Now" only, Daily/Weekly gate on the time since the last
            // successful backup. Forced (manual) backups skip this entirely.
            guard let minimumInterval = configuration.frequency.minimumInterval else {
                return nil
            }
            if let lastBackupAt = configuration.lastBackupAt,
               lastBackupAt.addingTimeInterval(minimumInterval) > Date() {
                return nil
            }
        }

        let encryptedArchive = try Self.encryptArchive(
            archiveData,
            aesKey: aesKey,
            hmacKey: hmacKey,
            snapshot: snapshot,
            contentHash: contentHash
        )

        // Fan out the same encrypted archive to every enabled destination. When
        // only iCloud is enabled, Sanchr's servers are never contacted — that is
        // the privacy promise the iCloud option makes.
        let destinations = configuration.destinations
        var serverDate: Date?
        var iCloudDate: Date?

        if destinations.contains(.sanchrCloud) {
            var createRequest = Sanchr_Backup_CreateBackupUploadRequest()
            createRequest.byteSize = Int64(encryptedArchive.ciphertext.count)
            createRequest.sha256Hash = Self.sha256Hex(encryptedArchive.ciphertext)
            createRequest.opaqueMetadata = encryptedArchive.metadataJSON
            createRequest.reservedForwardSecrecyMetadata = Data()
            createRequest.lineageID = configuration.lineageId
            createRequest.formatVersion = BackupArchive.formatVersion

            let upload = try await grpcClient.backupService.createBackupUpload(createRequest)
            try await Self.uploadObject(
                data: encryptedArchive.ciphertext,
                to: upload.uploadURL,
                session: session
            )

            var commitRequest = Sanchr_Backup_CommitBackupRequest()
            commitRequest.backupID = upload.backupID
            commitRequest.byteSize = createRequest.byteSize
            commitRequest.sha256Hash = createRequest.sha256Hash
            let committed = try await grpcClient.backupService.commitBackup(commitRequest)
            serverDate = Self.parseServerDate(
                committed.backup.committedAt.isEmpty ? committed.backup.createdAt : committed.backup.committedAt
            ) ?? Date()
        }

        if destinations.contains(.iCloud) {
            iCloudDate = try iCloudStore.writeBackup(
                ciphertext: encryptedArchive.ciphertext,
                metadataJSON: encryptedArchive.metadataJSON,
                lineageId: configuration.lineageId
            )
            // iCloud scope is chats AND media: stage the locally cached
            // attachment files (each re-encrypted under the backup key) next to
            // the archive. Incremental — files already staged are skipped, and
            // a failed or deferred media pass never fails the chat backup.
            stageMediaFilesToICloud(
                configuration: configuration,
                aesKey: aesKey,
                hmacKey: hmacKey
            )
        }

        guard let backupDate = serverDate ?? iCloudDate else {
            throw AppError.backupFailed(
                reason: "No backup destination is enabled. Turn on Sanchr Cloud or iCloud.")
        }
        return BackupUploadOutcome(
            backupDate: backupDate,
            contentHash: contentHash,
            iCloudBackupDate: iCloudDate
        )
    }

    func restoreLatestBackup(
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome {
        guard currentUserId?.isEmpty == false else {
            throw AppError.backupFailed(reason: "You must be signed in before restoring a backup.")
        }
        guard let aesKey = material.aesKey, let hmacKey = material.hmacKey else {
            throw AppError.backupFailed(reason: "Backup keys are unavailable for this account.")
        }

        let backups = try await grpcClient.backupService.listBackups(Sanchr_Backup_ListBackupsRequest()).backups
        guard let selected = Self.selectLatestBackup(from: backups, preferredLineageID: configuration?.lineageId) else {
            throw AppError.backupUnavailable
        }

        var request = Sanchr_Backup_GetBackupDownloadRequest()
        request.backupID = selected.backupID
        let response = try await grpcClient.backupService.getBackupDownload(request)
        let ciphertext = try await Self.downloadObject(from: response.downloadURL, session: session)
        let expectedSha = response.backup.sha256Hash.isEmpty ? selected.sha256Hash : response.backup.sha256Hash

        guard Self.sha256Hex(ciphertext) == expectedSha else {
            throw AppError.backupIntegrityCheckFailed(reason: "Encrypted backup SHA-256 did not match the committed metadata.")
        }

        let metadata = try JSONDecoder().decode(BackupOpaqueMetadata.self, from: response.backup.opaqueMetadata)
        let iv = Data(base64Encoded: metadata.ivBase64) ?? Data()
        let hmac = Data(base64Encoded: metadata.hmacBase64) ?? Data()
        let computedHMAC = Self.hmac(iv: iv, ciphertext: ciphertext, key: hmacKey)
        guard computedHMAC == hmac else {
            throw AppError.backupIntegrityCheckFailed(reason: "Backup HMAC verification failed.")
        }

        let plaintext = try Self.decryptArchive(ciphertext, aesKey: aesKey, iv: iv)
        let snapshot = try BackupArchiveSerializer.deserialize(plaintext)
        let localFingerprint = try deviceSecretProvider.backupFingerprint()
        try await localDatabase.restoreBackupSnapshot(
            snapshot,
            currentUserId: currentUserId,
            localFingerprint: localFingerprint
        )

        return BackupRestoreOutcome(
            lineageID: selected.lineageID,
            formatVersion: selected.formatVersion,
            backupDate: Self.parseServerDate(
                selected.committedAt.isEmpty ? selected.createdAt : selected.committedAt
            ),
            contentHash: metadata.contentHash
        )
    }

    func deleteRemoteBackups(lineageID: String?) async throws {
        // "Delete All Backups" means everywhere the app wrote one — clear the
        // user's iCloud copies alongside the server-side ones.
        try? iCloudStore.deleteAllBackups()

        let response = try await grpcClient.backupService.listBackups(Sanchr_Backup_ListBackupsRequest())
        let candidates = response.backups.filter { backup in
            guard let lineageID, !lineageID.isEmpty else { return true }
            return backup.lineageID == lineageID
        }

        for backup in candidates {
            var request = Sanchr_Backup_DeleteBackupRequest()
            request.backupID = backup.backupID
            _ = try await grpcClient.backupService.deleteBackup(request)
        }
    }

    func listBackups() async throws -> [BackupListEntry] {
        let response = try await grpcClient.backupService.listBackups(Sanchr_Backup_ListBackupsRequest())
        return response.backups
            .map { meta -> BackupListEntry in
                let date = Self.parseServerDate(
                    meta.committedAt.isEmpty ? meta.createdAt : meta.committedAt
                ) ?? Date()
                let messageCount: Int? = {
                    guard !meta.opaqueMetadata.isEmpty,
                          let parsed = try? JSONDecoder().decode(
                              BackupOpaqueMetadata.self, from: meta.opaqueMetadata
                          )
                    else { return nil }
                    return parsed.counts.messages
                }()
                return BackupListEntry(
                    id: meta.backupID,
                    committedAt: date,
                    byteSize: meta.byteSize,
                    messageCount: messageCount
                )
            }
            .sorted { $0.committedAt > $1.committedAt }
    }

    func restoreBackup(
        backupId: String,
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome {
        guard currentUserId?.isEmpty == false else {
            throw AppError.backupFailed(reason: "You must be signed in before restoring a backup.")
        }
        guard let aesKey = material.aesKey, let hmacKey = material.hmacKey else {
            throw AppError.backupFailed(reason: "Backup keys are unavailable for this account.")
        }

        var request = Sanchr_Backup_GetBackupDownloadRequest()
        request.backupID = backupId
        let response = try await grpcClient.backupService.getBackupDownload(request)
        let ciphertext = try await Self.downloadObject(from: response.downloadURL, session: session)
        let expectedSha = response.backup.sha256Hash
        guard !expectedSha.isEmpty else {
            throw AppError.backupFailed(reason: "Server did not return a checksum for backup \(backupId).")
        }
        guard Self.sha256Hex(ciphertext) == expectedSha else {
            throw AppError.backupIntegrityCheckFailed(
                reason: "Encrypted backup SHA-256 did not match the committed metadata."
            )
        }

        let metadata = try JSONDecoder().decode(
            BackupOpaqueMetadata.self, from: response.backup.opaqueMetadata
        )
        let iv = Data(base64Encoded: metadata.ivBase64) ?? Data()
        let hmac = Data(base64Encoded: metadata.hmacBase64) ?? Data()
        let computedHMAC = Self.hmac(iv: iv, ciphertext: ciphertext, key: hmacKey)
        guard computedHMAC == hmac else {
            throw AppError.backupIntegrityCheckFailed(reason: "Backup HMAC verification failed.")
        }

        let plaintext = try Self.decryptArchive(ciphertext, aesKey: aesKey, iv: iv)
        let snapshot = try BackupArchiveSerializer.deserialize(plaintext)
        let localFingerprint = try deviceSecretProvider.backupFingerprint()
        try await localDatabase.restoreBackupSnapshot(
            snapshot,
            currentUserId: currentUserId,
            localFingerprint: localFingerprint
        )

        return BackupRestoreOutcome(
            lineageID: response.backup.lineageID,
            formatVersion: response.backup.formatVersion,
            backupDate: Self.parseServerDate(
                response.backup.committedAt.isEmpty
                    ? response.backup.createdAt
                    : response.backup.committedAt
            ),
            contentHash: metadata.contentHash
        )
    }

    func latestICloudBackup() async -> ICloudRestoreCandidate? {
        guard let entry = try? iCloudStore.latestBackup() else { return nil }
        var messageCount: Int?
        var exportedAt: Date?
        if let payload = try? iCloudStore.readBackup(entry),
            let metadata = try? JSONDecoder().decode(
                BackupOpaqueMetadata.self, from: payload.metadataJSON)
        {
            messageCount = metadata.counts.messages
            exportedAt = Date(timeIntervalSince1970: Double(metadata.exportedAtMs) / 1000)
        }
        return ICloudRestoreCandidate(
            entry: entry, messageCount: messageCount, exportedAt: exportedAt)
    }

    func restoreLatestICloudBackup(
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome {
        guard currentUserId?.isEmpty == false else {
            throw AppError.backupFailed(reason: "You must be signed in before restoring a backup.")
        }
        guard let aesKey = material.aesKey, let hmacKey = material.hmacKey else {
            throw AppError.backupFailed(reason: "Backup keys are unavailable for this account.")
        }
        guard let entry = try? iCloudStore.latestBackup() else {
            throw AppError.backupUnavailable
        }

        let payload = try iCloudStore.readBackup(entry)
        let metadata = try JSONDecoder().decode(
            BackupOpaqueMetadata.self, from: payload.metadataJSON)
        let iv = Data(base64Encoded: metadata.ivBase64) ?? Data()
        let hmac = Data(base64Encoded: metadata.hmacBase64) ?? Data()
        let computedHMAC = Self.hmac(iv: iv, ciphertext: payload.ciphertext, key: hmacKey)
        guard computedHMAC == hmac else {
            throw AppError.backupIntegrityCheckFailed(reason: "Backup HMAC verification failed.")
        }

        let plaintext = try Self.decryptArchive(payload.ciphertext, aesKey: aesKey, iv: iv)
        let snapshot = try BackupArchiveSerializer.deserialize(plaintext)
        let localFingerprint = try deviceSecretProvider.backupFingerprint()
        try await localDatabase.restoreBackupSnapshot(
            snapshot,
            currentUserId: currentUserId,
            localFingerprint: localFingerprint
        )

        restoreStagedMediaFromICloud(
            lineageId: entry.lineageId, aesKey: aesKey, hmacKey: hmacKey)

        return BackupRestoreOutcome(
            lineageID: entry.lineageId,
            formatVersion: metadata.formatVersion,
            backupDate: entry.modifiedAt,
            contentHash: metadata.contentHash
        )
    }

    /// Decrypts the lineage's staged media files back into the local cache so
    /// restored chats show their attachments without re-downloading. Best-effort:
    /// a corrupt or unreadable file is skipped, never failing the chat restore
    /// that already succeeded.
    private func restoreStagedMediaFromICloud(lineageId: String, aesKey: Data, hmacKey: Data) {
        guard let names = try? iCloudStore.stagedMediaFileNames(lineageId: lineageId),
            !names.isEmpty
        else { return }
        let cacheDirectory = AppGroup.mediaCacheURL
            .appendingPathComponent("MediaMessages", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)

        var restored = 0
        for name in names {
            let target = cacheDirectory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                let sealed = try iCloudStore.readMediaFile(named: name, lineageId: lineageId)
                guard sealed.count > 48 else { continue }
                let iv = sealed.prefix(16)
                let mac = sealed.dropFirst(16).prefix(32)
                let ciphertext = sealed.dropFirst(48)
                guard
                    Self.hmac(iv: Data(iv), ciphertext: Data(ciphertext), key: hmacKey)
                        == Data(mac)
                else { continue }
                let plaintext = try Self.aesCBC(
                    operation: CCOperation(kCCDecrypt), input: Data(ciphertext), key: aesKey,
                    iv: Data(iv))
                try plaintext.write(to: target, options: .atomic)
                restored += 1
            } catch {
                SanchrLogger.persistence.warning(
                    "iCloud media restore skipped \(name): \(error.localizedDescription)")
            }
        }
        if restored > 0 {
            SanchrLogger.persistence.info("iCloud media restore: \(restored) file(s)")
        }
    }

    /// Copies newly cached media into the iCloud media folder for the lineage.
    ///
    /// Cache files are decrypted for display, so each is sealed with the backup
    /// AES key (per-file random IV, HMAC over iv+ciphertext, layout
    /// iv||hmac||ciphertext) before leaving the device. Honors the
    /// media-over-wifi-only preference by deferring staging to a later backup
    /// run when the connection is cellular. Media staging is best-effort by
    /// design: an individual file failure or a deferral must not fail the chat
    /// backup that just succeeded.
    private func stageMediaFilesToICloud(
        configuration: BackupConfiguration,
        aesKey: Data,
        hmacKey: Data
    ) {
        if configuration.wifiOnlyMedia,
            let monitor = networkMonitor,
            monitor.connectionType != .wifi
        {
            SanchrLogger.persistence.info("iCloud media staging deferred: waiting for Wi-Fi")
            return
        }

        let cacheDirectory = AppGroup.mediaCacheURL
            .appendingPathComponent("MediaMessages", isDirectory: true)
        let fileManager = FileManager.default
        guard
            let cached = try? fileManager.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: nil)
        else { return }

        let alreadyStaged =
            (try? iCloudStore.stagedMediaFileNames(lineageId: configuration.lineageId)) ?? []
        var staged = 0
        for fileURL in cached where !alreadyStaged.contains(fileURL.lastPathComponent) {
            do {
                let plaintext = try Data(contentsOf: fileURL)
                var ivBytes = [UInt8](repeating: 0, count: 16)
                guard SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes)
                    == errSecSuccess
                else { continue }
                let iv = Data(ivBytes)
                let ciphertext = try Self.aesCBC(
                    operation: CCOperation(kCCEncrypt), input: plaintext, key: aesKey, iv: iv)
                let mac = Self.hmac(iv: iv, ciphertext: ciphertext, key: hmacKey)
                try iCloudStore.writeMediaFile(
                    iv + mac + ciphertext,
                    named: fileURL.lastPathComponent,
                    lineageId: configuration.lineageId
                )
                staged += 1
            } catch {
                SanchrLogger.persistence.warning(
                    "iCloud media staging skipped \(fileURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        if staged > 0 {
            SanchrLogger.persistence.info("iCloud media staging: \(staged) file(s) added")
        }
    }

    private static func selectLatestBackup(
        from backups: [Sanchr_Backup_BackupMetadata],
        preferredLineageID: String?
    ) -> Sanchr_Backup_BackupMetadata? {
        let filtered = backups.filter { backup in
            guard let preferredLineageID, !preferredLineageID.isEmpty else { return true }
            return backup.lineageID == preferredLineageID
        }

        let candidates = filtered.isEmpty ? backups : filtered
        return candidates.max { lhs, rhs in
            let leftDate = parseServerDate(lhs.committedAt.isEmpty ? lhs.createdAt : lhs.committedAt) ?? .distantPast
            let rightDate = parseServerDate(rhs.committedAt.isEmpty ? rhs.createdAt : rhs.committedAt) ?? .distantPast
            return leftDate < rightDate
        }
    }

    private static func uploadObject(
        data: Data,
        to urlString: String,
        session: URLSession
    ) async throws {
        guard let url = URL(string: urlString) else {
            throw AppError.backupFailed(reason: "Backup upload URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, from: data)
        try validateHTTPResponse(response, context: "upload")
    }

    private static func downloadObject(from urlString: String, session: URLSession) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw AppError.backupFailed(reason: "Backup download URL is invalid.")
        }

        let (data, response) = try await session.data(from: url)
        try validateHTTPResponse(response, context: "download")
        return data
    }

    private static func validateHTTPResponse(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.backupFailed(reason: "Backup \(context) request failed.")
        }
    }

    private static func encryptArchive(
        _ archiveData: Data,
        aesKey: Data,
        hmacKey: Data,
        snapshot: BackupArchiveSnapshot,
        contentHash: String
    ) throws -> (ciphertext: Data, metadataJSON: Data) {
        let iv = randomBytes(count: kCCBlockSizeAES128)
        let ciphertext = try aesCBC(operation: CCOperation(kCCEncrypt), input: archiveData, key: aesKey, iv: iv)
        let metadata = BackupOpaqueMetadata(
            formatVersion: BackupArchive.formatVersion,
            ivBase64: iv.base64EncodedString(),
            hmacBase64: hmac(iv: iv, ciphertext: ciphertext, key: hmacKey).base64EncodedString(),
            exportedAtMs: snapshot.info.exportedAtMs,
            contentHash: contentHash,
            platform: snapshot.info.platform,
            appVersion: snapshot.info.appVersion,
            counts: snapshot.contentCounts
        )
        return (ciphertext, try JSONEncoder().encode(metadata))
    }

    private static func decryptArchive(_ ciphertext: Data, aesKey: Data, iv: Data) throws -> Data {
        try aesCBC(operation: CCOperation(kCCDecrypt), input: ciphertext, key: aesKey, iv: iv)
    }

    private static func aesCBC(operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw AppError.backupFailed(reason: "Backup AES-256 key has an invalid length.")
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw AppError.backupFailed(reason: "Backup IV has an invalid length.")
        }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCount = output.count
        var outputLength: size_t = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCount,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw AppError.backupFailed(reason: "Backup encryption failed with CommonCrypto status \(status).")
        }

        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private static func hmac(iv: Data, ciphertext: Data, key: Data) -> Data {
        var material = Data()
        material.append(iv)
        material.append(ciphertext)
        let symmetricKey = SymmetricKey(data: key)
        let digest = HMAC<SHA256>.authenticationCode(for: material, using: symmetricKey)
        return Data(digest)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func parseServerDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if let date = makeISO8601Formatter(withFractionalSeconds: true).date(from: value) {
            return date
        }
        return makeISO8601Formatter(withFractionalSeconds: false).date(from: value)
    }

    private static func makeISO8601Formatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
