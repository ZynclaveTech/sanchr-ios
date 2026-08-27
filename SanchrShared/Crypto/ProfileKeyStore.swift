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

    /// Whether our own Profile Key has already been handed to `userId`.
    ///
    /// Profile Key delivery is reciprocal: receiving a peer's key prompts us to
    /// send ours back. Without a record of who we have already told, the two
    /// sides would answer each other indefinitely.
    func hasSentOwnProfileKey(toUserId userId: String) -> Bool

    /// Records that our Profile Key has been delivered to `userId`.
    func markOwnProfileKeySent(toUserId userId: String)

    /// Whether a Profile Key exists yet for the local user.
    ///
    /// `ownProfileKey()` mints one on demand, so calling it can never tell you
    /// whether the key you got back is the one your profile on the server was
    /// encrypted under. This does, without creating anything.
    func hasOwnProfileKey() -> Bool

    /// Forgets which peers hold our Profile Key.
    ///
    /// Called when the key changes: every peer now holds one that no longer opens
    /// our ciphertext, so all of them have to be told again.
    func clearOwnProfileKeyDeliveryMarkers()
}

public final class ProfileKeyStore: ProfileKeyStoreProtocol, @unchecked Sendable {

    // MARK: - Keychain key strings

    private enum Keys {
        static let ownKey = "profile.key.own"
        static func contactKey(for userId: String) -> String {
            "profile.key.contact.\(userId)"
        }
        static func sentMarker(for userId: String) -> String {
            "profile.key.sent.\(userId)"
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
        // The own Profile Key is stored in the iCloud-synchronized namespace so it
        // survives a reinstall and reaches the user's other devices — this is what
        // makes the profile (name, avatar) recoverable rather than lost the moment
        // the app is deleted. Regenerating it would orphan the profile ciphertext
        // the old key produced, which is exactly the situation this avoids.

        // Fast path: read outside the queue (Keychain reads are concurrent-safe).
        if let existing = try ownProfileKeyFromKeychain() {
            return existing
        }
        // Slow path: generate-and-save is serialised so concurrent first callers
        // cannot produce two different keys.
        return try queue.sync {
            // Re-check inside the queue in case another caller already wrote it.
            if let existing = try ownProfileKeyFromKeychain() {
                return existing
            }
            var bytes = [UInt8](repeating: 0, count: profileKeyLength)
            let status = SecRandomCopyBytes(kSecRandomDefault, profileKeyLength, &bytes)
            guard status == errSecSuccess else {
                SanchrLogger.crypto.error("ProfileKeyStore: SecRandomCopyBytes failed: \(status)")
                throw AppError.keyGenerationFailed
            }
            let key = Data(bytes)
            try keychain.saveSynchronized(key, forKey: Keys.ownKey)
            return key
        }
    }

    /// Reads the own Profile Key, preferring the synchronized copy and migrating a
    /// legacy device-only key up into the synchronized namespace so it, too, will
    /// survive future reinstalls.
    private func ownProfileKeyFromKeychain() throws -> Data? {
        if let synced = try keychain.readSynchronized(forKey: Keys.ownKey) {
            return synced
        }
        if let legacy = try keychain.read(forKey: Keys.ownKey) {
            try? keychain.saveSynchronized(legacy, forKey: Keys.ownKey)
            return legacy
        }
        return nil
    }

    public func saveContactProfileKey(_ key: Data, forUserId userId: String) throws {
        try keychain.save(key, forKey: Keys.contactKey(for: userId))
    }

    public func contactProfileKey(forUserId userId: String) throws -> Data? {
        try keychain.read(forKey: Keys.contactKey(for: userId))
    }

    /// Delivery markers live in UserDefaults rather than the Keychain: they are
    /// not secret, and unlike the keys themselves they *should* be cleared when
    /// the app is deleted. A reinstall has a new Profile Key, so every peer needs
    /// telling again.
    public func hasOwnProfileKey() -> Bool {
        ((try? ownProfileKeyFromKeychain()) ?? nil) != nil
    }

    public func clearOwnProfileKeyDeliveryMarkers() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("profile.key.sent.") {
            defaults.removeObject(forKey: key)
        }
    }

    public func hasSentOwnProfileKey(toUserId userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: Keys.sentMarker(for: userId))
    }

    public func markOwnProfileKeySent(toUserId userId: String) {
        UserDefaults.standard.set(true, forKey: Keys.sentMarker(for: userId))
    }

    public func deleteContactProfileKey(forUserId userId: String) throws {
        try keychain.delete(forKey: Keys.contactKey(for: userId))
    }
}
