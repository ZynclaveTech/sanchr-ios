import CryptoKit
import Foundation

/// Manages per-conversation media chain keys for forward-secure media encryption.
/// Chain keys are advanced after each media derivation and the previous key is erased.
/// This is the client-side counterpart to the parallel HKDF chain described in the paper (Section 5).
public final class MediaChainState: @unchecked Sendable {
    private let deviceSecret: Data
    private var chainKeys: [String: Data] = [:]  // conversationId -> current chain key
    private let lock = NSLock()

    private enum Labels {
        static let chainInit = "sanchr-media-chain-init-v1"
        static let chainAdvance = "sanchr-media-chain-advance-v1"
    }

    /// The device-local secret (for AccessK derivation). Never transmitted.
    public var deviceSecretData: Data { deviceSecret }

    public init(deviceSecret: Data) {
        precondition(deviceSecret.count == 32, "device secret must be 32 bytes")
        self.deviceSecret = deviceSecret
    }

    // MARK: - Private helpers (must be called with lock held)

    /// Derives and stores the initial chain key for a conversation. Caller must hold `lock`.
    @discardableResult
    private func _initChainKey(conversationId: String) -> Data {
        let key = SymmetricKey(data: deviceSecret)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data(conversationId.utf8),
            info: Data(Labels.chainInit.utf8),
            outputByteCount: 32
        )
        let chainKey = derived.withUnsafeBytes { Data($0) }
        chainKeys[conversationId] = chainKey
        return chainKey
    }

    // MARK: - Public API

    /// Get the current chain key for a conversation, initializing if needed.
    /// Initialization: HKDF(device_secret, conversation_id, "sanchr-media-chain-init-v1")
    public func getOrInitChainKey(conversationId: String) -> Data {
        lock.lock()
        defer { lock.unlock() }

        if let existing = chainKeys[conversationId] {
            return existing
        }
        return _initChainKey(conversationId: conversationId)
    }

    /// Advance the chain key for a conversation (forward secrecy).
    /// Returns the NEW chain key. The old key is erased.
    @discardableResult
    public func advanceChainKey(conversationId: String) -> Data {
        lock.lock()
        defer { lock.unlock() }

        // Auto-init without releasing the lock to avoid a TOCTOU race.
        let current = chainKeys[conversationId] ?? _initChainKey(conversationId: conversationId)

        let key = SymmetricKey(data: current)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data(),
            info: Data(Labels.chainAdvance.utf8),
            outputByteCount: 32
        )
        let newKey = derived.withUnsafeBytes { Data($0) }
        chainKeys[conversationId] = newKey
        return newKey
    }

    /// Erase all chain state (e.g., on logout).
    public func eraseAll() {
        lock.lock()
        defer { lock.unlock() }
        chainKeys.removeAll()
    }
}
