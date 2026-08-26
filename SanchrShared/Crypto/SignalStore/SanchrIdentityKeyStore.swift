import Foundation
import LibSignalClient

extension Notification.Name {
    /// Posted when an identity change is first detected, or when one is resolved.
    /// The UI observes this so a key change surfaces while the chat is open rather
    /// than only on next appearance.
    public static let sanchrIdentityChangeStateDidChange = Notification.Name(
        "io.sanchr.crypto.identityChangeStateDidChange")
}

/// Manages identity key storage and trust decisions for the Signal Protocol.
///
/// The local identity key pair is persisted in the iOS Keychain via `KeychainServiceProtocol`.
/// Remote identity keys (trusted identities) are stored in an in-memory dictionary that is
/// also flushed to a file on disk so that trust decisions survive app restarts.
public final class SanchrIdentityKeyStore: IdentityKeyStore, @unchecked Sendable {

    // MARK: - Constants

    private enum KeychainKeys {
        static func identityKeyPair(userId: String) -> String {
            "io.sanchr.signal.identity_key_pair.\(userId)"
        }
        static func registrationId(userId: String) -> String {
            "io.sanchr.signal.registration_id.\(userId)"
        }
    }

    // MARK: - Properties

    private let userId: String
    private let keychain: KeychainServiceProtocol
    private let fileManager: FileManager

    /// Maps a remote `ProtocolAddress` (userId.deviceId) to the identity key we trust for them.
    private var trustedIdentities: [ProtocolAddress: IdentityKey] = [:]

    /// Set of user IDs whose identity has been manually verified by the local user
    /// (safety number comparison completed).
    private var verifiedUserIds: Set<String> = []

    /// When each verification happened, so the UI can state a real date instead of
    /// a placeholder. Entries predating this map decode without a timestamp and
    /// report `nil` rather than inventing one.
    private var verifiedAtByUserId: [String: Date] = [:]

    /// Addresses whose identity key changed and which the local user has not yet
    /// reviewed. While an address has an entry here, outbound encryption to it is
    /// refused so a substituted key cannot be used to transparently intercept a
    /// conversation. Cleared by `acceptIdentityChange(userId:)` (the user chose to
    /// continue) or `markIdentityVerified(userId:)` (the user compared the new
    /// safety number). The value is the new key that triggered the change.
    private var pendingIdentityChanges: [ProtocolAddress: IdentityKey] = [:]

    /// Serialisation queue to make trust store mutations thread-safe.
    private let queue = DispatchQueue(
        label: "io.sanchr.signal.identity-store", attributes: .concurrent)

    /// File URL where the trusted identities dictionary is persisted.
    private let persistenceURL: URL

    /// File URL where verified user IDs are persisted.
    private let verifiedURL: URL

    /// File URL where unreviewed identity changes are persisted.
    private let pendingChangesURL: URL

    /// Directory containing the persisted trust-store artifacts.
    private let storageDirectory: URL

    // MARK: - Init

    public init(
        userId: String,
        keychain: KeychainServiceProtocol,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.userId = userId
        self.keychain = keychain
        self.fileManager = fileManager

        let base = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SignalStore/\(userId)", isDirectory: true)
        self.storageDirectory = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.persistenceURL = dir.appendingPathComponent("trusted_identities.bin")
        self.verifiedURL = dir.appendingPathComponent("verified_identities.bin")
        self.pendingChangesURL = dir.appendingPathComponent("pending_identity_changes.bin")

        loadTrustedIdentitiesFromDisk()
        loadVerifiedFromDisk()
        loadPendingChangesFromDisk()
    }

    // MARK: - IdentityKeyStore Protocol

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        let key = KeychainKeys.identityKeyPair(userId: userId)
        guard let data = try keychain.read(forKey: key) else {
            throw AppError.keyGenerationFailed
        }
        return try IdentityKeyPair(bytes: [UInt8](data))
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 {
        let key = KeychainKeys.registrationId(userId: userId)
        guard let data = try keychain.read(forKey: key), data.count >= 4 else {
            throw AppError.keyGenerationFailed
        }
        return data.withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    public func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        var change: IdentityChange = .newOrUnchanged
        queue.sync(flags: .barrier) {
            if let existing = self.trustedIdentities[address], existing != identity {
                change = .replacedExisting
            }
            self.trustedIdentities[address] = identity
        }
        saveTrustedIdentitiesToDisk()
        return change
    }

    /// Decides whether `identity` may be used for `address`.
    ///
    /// Trust-on-first-use: an address we have never seen is trusted, and an unchanged
    /// key stays trusted. A *changed* key is the security-relevant case, because it is
    /// exactly what a malicious server substituting its own key would produce.
    ///
    /// When a change is detected it is recorded as pending review and any existing
    /// verification is revoked. From then on the two directions diverge:
    ///
    /// - `.receiving` returns `true`, so already-delivered messages still decrypt and
    ///   the conversation is not silently broken. libsignal then calls `saveIdentity`,
    ///   which adopts the new key.
    /// - `.sending` returns `false` while the change is unreviewed, so encryption
    ///   fails closed rather than handing plaintext to whoever supplied the new key.
    ///
    /// The send block is keyed on the pending record rather than on a key comparison:
    /// once the receiving path has adopted the new key there is no longer a difference
    /// to compare against, and gating on comparison alone would let the block lapse.
    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        var newlyChanged = false
        var changePending = false

        queue.sync(flags: .barrier) {
            if let existing = self.trustedIdentities[address], existing != identity,
                self.pendingIdentityChanges[address] == nil
            {
                // First observation of this change — record it and revoke verification.
                self.pendingIdentityChanges[address] = identity
                _ = self.verifiedUserIds.remove(address.name)
                self.verifiedAtByUserId.removeValue(forKey: address.name)
                newlyChanged = true
            }
            changePending = self.pendingIdentityChanges[address] != nil
        }

        if newlyChanged {
            SanchrLogger.crypto.warning(
                "Identity key changed for \(address.name.prefix(8))... device \(address.deviceId) — sending blocked pending user review"
            )
            savePendingChangesToDisk()
            saveVerifiedToDisk()
            postIdentityChangeStateChanged(userId: address.name)
        }

        guard changePending else { return true }

        switch direction {
        case .sending:
            return false
        default:
            // Receiving (and any future direction) stays readable.
            return true
        }
    }

    public func identity(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityKey? {
        var result: IdentityKey?
        queue.sync {
            result = self.trustedIdentities[address]
        }
        return result
    }

    // MARK: - Key Generation Helpers

    /// Generates a new identity key pair and registration ID, storing both in the Keychain.
    /// Call this once during registration or first device login.
    public func generateAndStoreIdentity() throws -> IdentityKeyPair {
        let identityKeyPair = IdentityKeyPair.generate()
        let serialized = Data(identityKeyPair.serialize())
        try keychain.save(serialized, forKey: KeychainKeys.identityKeyPair(userId: userId))

        // Generate a random 32-bit registration ID
        let registrationId = UInt32.random(in: 1...0x3FFF)
        var regIdBytes = registrationId
        let regIdData = Data(bytes: &regIdBytes, count: MemoryLayout<UInt32>.size)
        try keychain.save(regIdData, forKey: KeychainKeys.registrationId(userId: userId))

        SanchrLogger.crypto.info("Generated and stored identity key pair + registration ID")
        return identityKeyPair
    }

    /// Returns `true` if identity keys have already been generated for this user.
    var hasIdentityKeys: Bool {
        let key = KeychainKeys.identityKeyPair(userId: userId)
        return (try? keychain.read(forKey: key)) != nil
    }

    // MARK: - Identity Verification

    /// Returns whether the given user has been manually verified (safety number confirmed).
    public func isIdentityVerified(userId: String) -> Bool {
        queue.sync { self.verifiedUserIds.contains(userId) }
    }

    /// When `userId` was verified, or nil if they are unverified or were verified
    /// before timestamps were recorded.
    public func identityVerifiedAt(userId: String) -> Date? {
        queue.sync { self.verifiedAtByUserId[userId] }
    }

    /// Marks a user's identity as verified after safety number comparison.
    ///
    /// Comparing the new safety number is a strictly stronger review than simply
    /// acknowledging the change, so this also clears any pending change and unblocks
    /// sending.
    public func markIdentityVerified(userId: String) {
        queue.sync(flags: .barrier) {
            _ = self.verifiedUserIds.insert(userId)
            self.verifiedAtByUserId[userId] = Date()
            self.adoptPendingChangesLocked(userId: userId)
        }
        saveVerifiedToDisk()
        savePendingChangesToDisk()
        saveTrustedIdentitiesToDisk()
        postIdentityChangeStateChanged(userId: userId)
        SanchrLogger.crypto.info("Marked identity verified for \(userId.prefix(8))...")
    }

    // MARK: - Identity Change Review

    /// Whether `userId` has an identity change the local user has not yet reviewed.
    /// While this is `true`, sending to that user fails with `AppError.untrustedIdentity`.
    public func hasPendingIdentityChange(userId: String) -> Bool {
        queue.sync {
            self.pendingIdentityChanges.keys.contains { $0.name == userId }
        }
    }

    /// All user IDs with an unreviewed identity change.
    public func usersWithPendingIdentityChanges() -> Set<String> {
        queue.sync { Set(self.pendingIdentityChanges.keys.map(\.name)) }
    }

    /// Records that the local user reviewed the change for `userId` and chose to
    /// continue, adopting the new key and unblocking sending.
    ///
    /// This does *not* mark the identity verified: the user acknowledged the change
    /// without necessarily comparing safety numbers. Use `markIdentityVerified` for that.
    public func acceptIdentityChange(userId: String) {
        queue.sync(flags: .barrier) {
            self.adoptPendingChangesLocked(userId: userId)
        }
        savePendingChangesToDisk()
        saveTrustedIdentitiesToDisk()
        postIdentityChangeStateChanged(userId: userId)
        SanchrLogger.crypto.info(
            "Accepted identity change for \(userId.prefix(8))... — sending unblocked")
    }

    /// Moves every pending key for `userId` into the trusted set.
    /// Caller must already hold the barrier.
    private func adoptPendingChangesLocked(userId: String) {
        for (address, identity) in pendingIdentityChanges where address.name == userId {
            trustedIdentities[address] = identity
            pendingIdentityChanges.removeValue(forKey: address)
        }
    }

    private func postIdentityChangeStateChanged(userId: String) {
        NotificationCenter.default.post(
            name: .sanchrIdentityChangeStateDidChange,
            object: nil,
            userInfo: ["userId": userId]
        )
    }

    /// Removes verification for a user (e.g., after unblock or manual reset).
    public func unmarkIdentityVerified(userId: String) {
        queue.sync(flags: .barrier) {
            _ = self.verifiedUserIds.remove(userId)
            self.verifiedAtByUserId.removeValue(forKey: userId)
        }
        saveVerifiedToDisk()
    }

    /// Clears all verified identity flags (e.g., after a local identity key reset).
    /// All contacts must re-verify safety numbers under the new identity.
    public func clearAllVerifications() {
        queue.sync(flags: .barrier) {
            self.verifiedUserIds.removeAll()
            self.verifiedAtByUserId.removeAll()
        }
        saveVerifiedToDisk()
        SanchrLogger.crypto.info("Cleared all identity verifications after key reset")
    }

    // MARK: - Persistence Helpers

    private func saveTrustedIdentitiesToDisk() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            do {
                try self.ensureStorageDirectoryExists()
                var entries: [[String: Data]] = []
                for (address, identityKey) in self.trustedIdentities {
                    let addressKey = "\(address.name).\(address.deviceId)"
                    let keyData = Data(identityKey.serialize())
                    entries.append(["address": Data(addressKey.utf8), "key": keyData])
                }
                let archived = try JSONEncoder().encode(entries)
                try archived.write(to: self.persistenceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                SanchrLogger.crypto.error(
                    "Failed to persist trusted identities: \(error.localizedDescription)")
            }
        }
    }

    private func loadTrustedIdentitiesFromDisk() {
        guard FileManager.default.fileExists(atPath: self.persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: self.persistenceURL)
            let entries = try JSONDecoder().decode([[String: Data]].self, from: data)
            for entry in entries {
                guard let addressData = entry["address"],
                    let keyData = entry["key"],
                    let addressString = String(data: addressData, encoding: .utf8)
                else {
                    continue
                }
                let components = addressString.split(separator: ".")
                guard components.count >= 2,
                    let deviceId = UInt32(components.last!)
                else { continue }
                let name = components.dropLast().joined(separator: ".")
                let address = try ProtocolAddress(name: name, deviceId: deviceId)
                let identityKey = try IdentityKey(bytes: [UInt8](keyData))
                self.trustedIdentities[address] = identityKey
            }
            SanchrLogger.crypto.info(
                "Loaded \(self.trustedIdentities.count) trusted identities from disk")
        } catch {
            SanchrLogger.crypto.error(
                "Failed to load trusted identities: \(error.localizedDescription)")
        }
    }

    private func saveVerifiedToDisk() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            do {
                try self.ensureStorageDirectoryExists()
                // Written as a dictionary of userId -> verifiedAt. Older builds
                // wrote a bare array; `loadVerifiedFromDisk` still reads that.
                var payload: [String: Double] = [:]
                for id in self.verifiedUserIds {
                    payload[id] = self.verifiedAtByUserId[id]?.timeIntervalSince1970 ?? 0
                }
                let data = try JSONEncoder().encode(payload)
                try data.write(to: self.verifiedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                SanchrLogger.crypto.error("Failed to persist verified identities: \(error.localizedDescription)")
            }
        }
    }

    private func loadVerifiedFromDisk() {
        guard FileManager.default.fileExists(atPath: self.verifiedURL.path) else { return }
        do {
            let data = try Data(contentsOf: self.verifiedURL)
            if let payload = try? JSONDecoder().decode([String: Double].self, from: data) {
                self.verifiedUserIds = Set(payload.keys)
                // 0 marks an entry written before timestamps existed. Report it as
                // unknown rather than claiming the epoch, so the UI can say
                // "verified" without inventing a date.
                self.verifiedAtByUserId = payload.compactMapValues {
                    $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
                }
            } else {
                // Legacy format: a bare array of ids, no timestamps.
                let ids = try JSONDecoder().decode([String].self, from: data)
                self.verifiedUserIds = Set(ids)
                self.verifiedAtByUserId = [:]
            }
            SanchrLogger.crypto.info("Loaded \(self.verifiedUserIds.count) verified identities from disk")
        } catch {
            SanchrLogger.crypto.error("Failed to load verified identities: \(error.localizedDescription)")
        }
    }

    private func savePendingChangesToDisk() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            do {
                try self.ensureStorageDirectoryExists()
                var entries: [[String: Data]] = []
                for (address, identityKey) in self.pendingIdentityChanges {
                    let addressKey = "\(address.name).\(address.deviceId)"
                    entries.append([
                        "address": Data(addressKey.utf8),
                        "key": Data(identityKey.serialize()),
                    ])
                }
                let archived = try JSONEncoder().encode(entries)
                try archived.write(to: self.pendingChangesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                SanchrLogger.crypto.error(
                    "Failed to persist pending identity changes: \(error.localizedDescription)")
            }
        }
    }

    private func loadPendingChangesFromDisk() {
        guard FileManager.default.fileExists(atPath: self.pendingChangesURL.path) else { return }
        do {
            let data = try Data(contentsOf: self.pendingChangesURL)
            let entries = try JSONDecoder().decode([[String: Data]].self, from: data)
            for entry in entries {
                guard let addressData = entry["address"],
                    let keyData = entry["key"],
                    let addressString = String(data: addressData, encoding: .utf8)
                else { continue }
                let components = addressString.split(separator: ".")
                guard components.count >= 2, let deviceId = UInt32(components.last!) else {
                    continue
                }
                let name = components.dropLast().joined(separator: ".")
                let address = try ProtocolAddress(name: name, deviceId: deviceId)
                self.pendingIdentityChanges[address] = try IdentityKey(bytes: [UInt8](keyData))
            }
            if !self.pendingIdentityChanges.isEmpty {
                SanchrLogger.crypto.warning(
                    "Loaded \(self.pendingIdentityChanges.count) unreviewed identity change(s) — sending to those contacts is blocked"
                )
            }
        } catch {
            SanchrLogger.crypto.error(
                "Failed to load pending identity changes: \(error.localizedDescription)")
        }
    }

    private func ensureStorageDirectoryExists() throws {
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }
}
