import Foundation
import CryptoKit

/// Protocol for cryptographic key lifecycle management.
protocol KeyManagerProtocol: AnyObject, Sendable {
    /// Generates a new identity key pair for this device.
    func generateIdentityKeyPair() async throws -> (publicKey: Data, privateKey: Data)

    /// Generates a batch of one-time pre-keys.
    func generatePreKeys(count: Int) async throws -> [(id: UInt32, publicKey: Data, privateKey: Data)]

    /// Generates a new signed pre-key.
    func generateSignedPreKey() async throws -> (id: UInt32, publicKey: Data, signature: Data, privateKey: Data)

    /// Retrieves the local identity public key.
    func localIdentityPublicKey() async throws -> Data?

    /// Checks if identity keys have been generated.
    var hasIdentityKeys: Bool { get }
}

/// Manages generation and secure storage of Signal Protocol keys.
final class KeyManager: KeyManagerProtocol, @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol

    private(set) var hasIdentityKeys: Bool = false

    init(secureStorage: SecureStorageProtocol) {
        self.secureStorage = secureStorage
        // Check if keys already exist
        hasIdentityKeys = (try? secureStorage.readIdentityKey()) != nil
    }

    func generateIdentityKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        SanchrLogger.crypto.info("Generating identity key pair")

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey

        let publicKeyData = publicKey.rawRepresentation
        let privateKeyData = privateKey.rawRepresentation

        // Store identity key in secure storage
        try secureStorage.saveIdentityKey(privateKeyData)
        hasIdentityKeys = true

        SanchrLogger.crypto.info("Identity key pair generated and stored")
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }

    func generatePreKeys(count: Int) async throws -> [(id: UInt32, publicKey: Data, privateKey: Data)] {
        SanchrLogger.crypto.info("Generating \(count) pre-keys")

        var preKeys: [(id: UInt32, publicKey: Data, privateKey: Data)] = []
        for i in 0..<count {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            preKeys.append((
                id: UInt32(i),
                publicKey: privateKey.publicKey.rawRepresentation,
                privateKey: privateKey.rawRepresentation
            ))
        }

        // TODO: Store pre-keys in secure storage indexed by ID
        let publicKeys = preKeys.map { $0.privateKey }
        try secureStorage.savePreKeys(publicKeys)

        return preKeys
    }

    func generateSignedPreKey() async throws -> (id: UInt32, publicKey: Data, signature: Data, privateKey: Data) {
        SanchrLogger.crypto.info("Generating signed pre-key")

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation

        // TODO: Sign the public key with the identity key using Ed25519
        // For now, placeholder signature
        let signature = Data(repeating: 0, count: 64)

        return (
            id: UInt32(Date().timeIntervalSince1970),
            publicKey: publicKeyData,
            signature: signature,
            privateKey: privateKey.rawRepresentation
        )
    }

    func localIdentityPublicKey() async throws -> Data? {
        guard let privateKeyData = try secureStorage.readIdentityKey() else { return nil }
        // Reconstruct public key from private key
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        return privateKey.publicKey.rawRepresentation
    }
}
