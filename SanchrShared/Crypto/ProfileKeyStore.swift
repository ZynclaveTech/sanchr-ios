// SanchrShared/Crypto/ProfileKeyStore.swift
import Foundation
import Security

/// Persists the local user's own Profile Key and received contacts' Profile Keys in the iOS Keychain.
///
/// Own key lifecycle: generated once on first call to `ownProfileKey()`, then read from Keychain
/// on all subsequent calls. Never changes unless the user explicitly resets (out of scope here).
///
/// Contact key lifecycle: populated from the `profile_key` bytes field in `GetContactsResponse`
/// whenever a contact is fetched. Used by `ContactRepositoryImpl` to decrypt profile fields.
public protocol ProfileKeyStoreProtocol: AnyObject, Sendable {
    /// Returns the local user's 32-byte Profile Key, generating and persisting it on first call.
    func ownProfileKey() throws -> Data

    /// Persists (or overwrites) a contact's Profile Key in the Keychain.
    func saveContactProfileKey(_ key: Data, forUserId userId: String) throws

    /// Reads a contact's Profile Key, or returns `nil` if not yet received.
    func contactProfileKey(forUserId userId: String) throws -> Data?

    /// Removes a contact's stored Profile Key (e.g. when a contact is deleted).
    func deleteContactProfileKey(forUserId userId: String) throws
}

public final class ProfileKeyStore: ProfileKeyStoreProtocol, @unchecked Sendable {

    // MARK: - Keychain key strings

    private enum Keys {
        static let ownKey = "profile.key.own"
        static func contactKey(for userId: String) -> String {
            "profile.key.contact.\(userId)"
        }
    }

    private let keychain: KeychainServiceProtocol
    private let queue = DispatchQueue(label: "io.sanchr.profile-key-store", attributes: [])
    private let profileKeyLength = 32

    public init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    // MARK: - ProfileKeyStoreProtocol

    public func ownProfileKey() throws -> Data {
        // Fast path: read outside the queue (Keychain reads are concurrent-safe).
        if let existing = try keychain.read(forKey: Keys.ownKey) {
            return existing
        }
        // Slow path: generate-and-save is serialised so concurrent first callers
        // cannot produce two different keys.
        return try queue.sync {
            // Re-check inside the queue in case another caller already wrote it.
            if let existing = try keychain.read(forKey: Keys.ownKey) {
                return existing
            }
            var bytes = [UInt8](repeating: 0, count: profileKeyLength)
            let status = SecRandomCopyBytes(kSecRandomDefault, profileKeyLength, &bytes)
            guard status == errSecSuccess else {
                SanchrLogger.crypto.error("ProfileKeyStore: SecRandomCopyBytes failed: \(status)")
                throw AppError.keyGenerationFailed
            }
            let key = Data(bytes)
            try keychain.save(key, forKey: Keys.ownKey)
            return key
        }
    }

    public func saveContactProfileKey(_ key: Data, forUserId userId: String) throws {
        try keychain.save(key, forKey: Keys.contactKey(for: userId))
    }

    public func contactProfileKey(forUserId userId: String) throws -> Data? {
        try keychain.read(forKey: Keys.contactKey(for: userId))
    }

    public func deleteContactProfileKey(forUserId userId: String) throws {
        try keychain.delete(forKey: Keys.contactKey(for: userId))
    }
}
