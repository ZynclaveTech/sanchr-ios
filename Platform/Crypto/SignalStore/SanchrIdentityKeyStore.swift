import Foundation
import LibSignalClient

/// Manages identity key storage and trust decisions for the Signal Protocol.
///
/// The local identity key pair is persisted in the iOS Keychain via `KeychainServiceProtocol`.
/// Remote identity keys (trusted identities) are stored in an in-memory dictionary that is
/// also flushed to a file on disk so that trust decisions survive app restarts.
final class SanchrIdentityKeyStore: IdentityKeyStore, @unchecked Sendable {

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

    /// Maps a remote `ProtocolAddress` (userId.deviceId) to the identity key we trust for them.
    private var trustedIdentities: [ProtocolAddress: IdentityKey] = [:]

    /// Set of user IDs whose identity has been manually verified by the local user
    /// (safety number comparison completed).
    private var verifiedUserIds: Set<String> = []

    /// Serialisation queue to make trust store mutations thread-safe.
    private let queue = DispatchQueue(
        label: "io.sanchr.signal.identity-store", attributes: .concurrent)

    /// File URL where the trusted identities dictionary is persisted.
    private let persistenceURL: URL

    /// File URL where verified user IDs are persisted.
    private let verifiedURL: URL

    // MARK: - Init

    init(userId: String, keychain: KeychainServiceProtocol) {
        self.userId = userId
        self.keychain = keychain

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = base.appendingPathComponent("SignalStore/\(userId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.persistenceURL = dir.appendingPathComponent("trusted_identities.bin")
        self.verifiedURL = dir.appendingPathComponent("verified_identities.bin")

        loadTrustedIdentitiesFromDisk()
        loadVerifiedFromDisk()
    }

    // MARK: - IdentityKeyStore Protocol

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        let key = KeychainKeys.identityKeyPair(userId: userId)
        guard let data = try keychain.read(forKey: key) else {
            throw AppError.keyGenerationFailed
        }
        return try IdentityKeyPair(bytes: [UInt8](data))
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        let key = KeychainKeys.registrationId(userId: userId)
        guard let data = try keychain.read(forKey: key), data.count >= 4 else {
            throw AppError.keyGenerationFailed
        }
        return data.withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        var change: IdentityChange = .newOrUnchanged
        queue.sync(flags: .barrier) {
            if let existing = trustedIdentities[address], existing != identity {
                change = .replacedExisting
            }
            trustedIdentities[address] = identity
        }
        saveTrustedIdentitiesToDisk()
        return change
    }

    func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        var keyChanged = false
        queue.sync {
            if let existing = trustedIdentities[address], existing != identity {
                keyChanged = true
            }
        }

        if keyChanged {
            // Identity key changed — auto-accept for sending (Signal's default behavior).
            // For receiving direction, also accept but log a warning.
            // In production, surface a "safety number changed" UI notification.
            SanchrLogger.crypto.warning(
                "Identity key changed for \(address.name.prefix(8))... device \(address.deviceId) — auto-accepting new key"
            )
            queue.sync(flags: .barrier) {
                self.trustedIdentities[address] = identity
                // Identity changed — reset verification
                _ = self.verifiedUserIds.remove(address.name)
            }
            saveTrustedIdentitiesToDisk()
            saveVerifiedToDisk()
        }

        return true
    }

    func identity(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityKey? {
        var result: IdentityKey?
        queue.sync {
            result = trustedIdentities[address]
        }
        return result
    }

    // MARK: - Key Generation Helpers

    /// Generates a new identity key pair and registration ID, storing both in the Keychain.
    /// Call this once during registration or first device login.
    func generateAndStoreIdentity() throws -> IdentityKeyPair {
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
    func isIdentityVerified(userId: String) -> Bool {
        queue.sync { self.verifiedUserIds.contains(userId) }
    }

    /// Marks a user's identity as verified after safety number comparison.
    func markIdentityVerified(userId: String) {
        queue.sync(flags: .barrier) {
            _ = self.verifiedUserIds.insert(userId)
        }
        saveVerifiedToDisk()
        SanchrLogger.crypto.info("Marked identity verified for \(userId.prefix(8))...")
    }

    /// Removes verification for a user (e.g., after unblock or manual reset).
    func unmarkIdentityVerified(userId: String) {
        queue.sync(flags: .barrier) {
            _ = self.verifiedUserIds.remove(userId)
        }
        saveVerifiedToDisk()
    }

    // MARK: - Persistence Helpers

    private func saveTrustedIdentitiesToDisk() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            do {
                var entries: [[String: Data]] = []
                for (address, identityKey) in self.trustedIdentities {
                    let addressKey = "\(address.name).\(address.deviceId)"
                    let keyData = Data(identityKey.serialize())
                    entries.append(["address": Data(addressKey.utf8), "key": keyData])
                }
                let archived = try JSONEncoder().encode(entries)
                try archived.write(to: self.persistenceURL, options: .atomic)
            } catch {
                SanchrLogger.crypto.error(
                    "Failed to persist trusted identities: \(error.localizedDescription)")
            }
        }
    }

    private func loadTrustedIdentitiesFromDisk() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
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
                let data = try JSONEncoder().encode(Array(self.verifiedUserIds))
                try data.write(to: self.verifiedURL, options: .atomic)
            } catch {
                SanchrLogger.crypto.error("Failed to persist verified identities: \(error.localizedDescription)")
            }
        }
    }

    private func loadVerifiedFromDisk() {
        guard FileManager.default.fileExists(atPath: verifiedURL.path) else { return }
        do {
            let data = try Data(contentsOf: verifiedURL)
            let ids = try JSONDecoder().decode([String].self, from: data)
            verifiedUserIds = Set(ids)
            SanchrLogger.crypto.info("Loaded \(verifiedUserIds.count) verified identities from disk")
        } catch {
            SanchrLogger.crypto.error("Failed to load verified identities: \(error.localizedDescription)")
        }
    }
}
