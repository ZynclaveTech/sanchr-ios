// SanchrShared/Crypto/ProfileCrypto.swift
import CryptoKit
import Foundation

/// Identifies which profile field is being encrypted.
/// The raw value is the HKDF info string — different fields derive different subkeys,
/// preventing cross-field ciphertext reuse.
public enum ProfileField: String, Sendable {
    case displayName = "sanchr-profile-display-name-v1"
    case bio         = "sanchr-profile-bio-v1"
    case avatarURL   = "sanchr-profile-avatar-url-v1"
}

/// Encrypts and decrypts individual profile fields using a per-field AES-256-GCM key
/// derived from a 32-byte master Profile Key via HKDF-SHA256.
public protocol ProfileCryptoProtocol: Sendable {
    /// Encrypts `plaintext` using a subkey derived from `profileKey` for `field`.
    /// Returns AES-GCM combined output (12-byte nonce ‖ ciphertext ‖ 16-byte tag).
    func encryptField(_ plaintext: String, profileKey: Data, field: ProfileField) throws -> Data

    /// Decrypts a ciphertext produced by `encryptField`.
    func decryptField(_ ciphertext: Data, profileKey: Data, field: ProfileField) throws -> String
}

/// Concrete AES-256-GCM implementation of `ProfileCryptoProtocol`.
public final class ProfileCryptor: ProfileCryptoProtocol, @unchecked Sendable {
    public init() {}

    // MARK: - ProfileCryptoProtocol

    public func encryptField(
        _ plaintext: String,
        profileKey: Data,
        field: ProfileField
    ) throws -> Data {
        guard profileKey.count == 32 else {
            throw AppError.encryptionFailed(reason: "profileKey must be 32 bytes, got \(profileKey.count)")
        }
        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw AppError.encryptionFailed(reason: "profile field is not valid UTF-8")
        }
        let symmetricKey = deriveFieldKey(profileKey: profileKey, field: field)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintextData, using: symmetricKey, nonce: nonce)
        guard let combined = box.combined else {
            throw AppError.encryptionFailed(reason: "AES-GCM produced no combined output")
        }
        return combined
    }

    public func decryptField(
        _ ciphertext: Data,
        profileKey: Data,
        field: ProfileField
    ) throws -> String {
        guard profileKey.count == 32 else {
            throw AppError.decryptionFailed(reason: "profileKey must be 32 bytes, got \(profileKey.count)")
        }
        let symmetricKey = deriveFieldKey(profileKey: profileKey, field: field)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintextData: Data
        do {
            plaintextData = try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw AppError.decryptionFailed(reason: "profile field AES-GCM open failed: \(error)")
        }
        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw AppError.decryptionFailed(reason: "decrypted profile field is not valid UTF-8")
        }
        return plaintext
    }

    // MARK: - Key Derivation

    private func deriveFieldKey(profileKey: Data, field: ProfileField) -> SymmetricKey {
        let ikm = SymmetricKey(data: profileKey)
        let info = Data(field.rawValue.utf8)
        // No salt: HKDF-SHA256 with empty salt is standard for key derivation from a
        // uniformly random IKM. The info string provides domain separation per field.
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: info,
            outputByteCount: 32
        )
    }
}
