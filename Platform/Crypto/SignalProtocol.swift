import Foundation
import GRPC
import LibSignalClient

/// Protocol for Signal Protocol session management and message encryption/decryption.
protocol SignalProtocolManagerProtocol: AnyObject, Sendable {
    /// Establishes a new session with a recipient using X3DH key agreement.
    func establishSession(with userId: String, deviceId: Int32) async throws

    /// Checks if an active session exists with a recipient device.
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool

    /// Encrypts plaintext for a specific recipient device.
    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data

    /// Encrypts a message for all devices of a recipient.
    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws
        -> [Vync_Messaging_DeviceMessage]

    /// Decrypts an incoming ciphertext from a sender device.
    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data

    /// Decrypts an EncryptedEnvelope, auto-detecting message type.
    func decryptEnvelope(_ envelope: Vync_Messaging_EncryptedEnvelope) async throws -> Data

    /// Resets (deletes) the session with a specific user/device for session recovery.
    func resetSession(with userId: String, deviceId: Int32) throws

    /// Generates a displayable safety number for identity verification.
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String

    /// Generates the scannable fingerprint data for QR code comparison.
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data

    /// Compares a scanned fingerprint with the local one. Returns true if they match.
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool

    /// Marks a contact's identity as manually verified.
    func markIdentityVerified(userId: String)

    /// Returns whether a contact's identity has been manually verified.
    func isIdentityVerified(userId: String) -> Bool

    /// Legacy compatibility shim: check session by userId only (assumes device 1).
    func hasSession(with userId: String) -> Bool
}

/// Signal Protocol session management and message encryption/decryption engine.
///
/// Uses libsignal-swift to implement X3DH key agreement and Double Ratchet messaging.
/// All cryptographic state is held in `SanchrSignalStore` which persists to Keychain and disk.
final class SignalSessionManager: SignalProtocolManagerProtocol, @unchecked Sendable {

    // MARK: - Properties

    private let store: SanchrSignalStore
    private let keyManager: SignalKeyManager

    // MARK: - Init

    init(store: SanchrSignalStore, keyManager: SignalKeyManager) {
        self.store = store
        self.keyManager = keyManager
        SanchrLogger.crypto.info("SignalSessionManager initialized")
    }

    // MARK: - Session Management

    func establishSession(with userId: String, deviceId: Int32) async throws {
        let address = try ProtocolAddress(name: userId, deviceId: UInt32(deviceId))

        SanchrLogger.crypto.info(
            "Establishing session with \(userId.prefix(8))... device \(deviceId)")

        // 1. Fetch the recipient's pre-key bundle from the server.
        let preKeyBundle: PreKeyBundle
        do {
            preKeyBundle = try await keyManager.fetchPreKeyBundle(
                userId: userId, deviceId: deviceId)
        } catch {
            SanchrLogger.crypto.error(
                "fetchPreKeyBundle FAILED for \(userId.prefix(8))... device \(deviceId): \(Self.detailedError(error))")
            throw error
        }

        // 2. Process the bundle to perform X3DH key agreement and initialize the Double Ratchet.
        do {
            try processPreKeyBundle(
                preKeyBundle,
                for: address,
                sessionStore: store,
                identityStore: store,
                context: NullContext()
            )
        } catch {
            SanchrLogger.crypto.error(
                "processPreKeyBundle FAILED for \(userId.prefix(8))... device \(deviceId): \(Self.detailedError(error))")
            throw error
        }

        SanchrLogger.crypto.info(
            "Session established with \(userId.prefix(8))... device \(deviceId)")
    }

    func hasSession(with userId: String, deviceId: Int32) throws -> Bool {
        let address = try ProtocolAddress(name: userId, deviceId: UInt32(deviceId))
        return store.sessionStore.hasSession(for: address)
    }

    /// Legacy compatibility: checks device 1 only.
    func hasSession(with userId: String) -> Bool {
        guard let address = try? ProtocolAddress(name: userId, deviceId: 1) else { return false }
        return store.sessionStore.hasSession(for: address)
    }

    // MARK: - Message Encryption

    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data {
        let address = try ProtocolAddress(name: userId, deviceId: UInt32(deviceId))

        // Ensure a session exists; establish one if needed.
        if !store.sessionStore.hasSession(for: address) {
            try await establishSession(with: userId, deviceId: deviceId)
        }

        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: address,
            sessionStore: store,
            identityStore: store,
            context: NullContext()
        )

        // Prepend a single byte indicating the message type so the receiver can dispatch correctly.
        // 0x01 = PreKeySignalMessage (new session), 0x02 = SignalMessage (existing session)
        var envelope = Data()
        switch ciphertext.messageType {
        case .preKey:
            envelope.append(0x01)
        case .whisper:
            envelope.append(0x02)
        default:
            envelope.append(0x00)
        }
        envelope.append(Data(ciphertext.serialize()))

        return envelope
    }

    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws
        -> [Vync_Messaging_DeviceMessage]
    {
        // Fetch all device IDs for this recipient from the server.
        let deviceIds: [Int32]
        do {
            deviceIds = try await keyManager.fetchUserDevices(recipientId: recipientId)
            SanchrLogger.crypto.info("Got \(deviceIds.count) device(s) for \(recipientId.prefix(8))...: \(deviceIds)")
        } catch {
            SanchrLogger.crypto.error("fetchUserDevices FAILED for \(recipientId.prefix(8))...: \(Self.detailedError(error))")
            throw error
        }

        var deviceMessages: [Vync_Messaging_DeviceMessage] = []
        deviceMessages.reserveCapacity(deviceIds.count)

        for deviceId in deviceIds {
            let ciphertext = try await encrypt(
                plaintext: plaintext, for: recipientId, deviceId: deviceId)

            var dm = Vync_Messaging_DeviceMessage()
            dm.recipientID = recipientId
            dm.deviceID = deviceId
            dm.ciphertext = ciphertext
            deviceMessages.append(dm)
        }

        return deviceMessages
    }

    // MARK: - Message Decryption

    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data
    {
        guard !ciphertext.isEmpty else {
            throw AppError.decryptionFailed(reason: "Empty ciphertext")
        }

        let address = try ProtocolAddress(name: senderId, deviceId: UInt32(senderDevice))

        // Read the type byte we prepended during encryption.
        let typeByte = ciphertext[ciphertext.startIndex]
        let messageData = ciphertext.dropFirst()

        let plaintext: Data
        switch typeByte {
        case 0x01:
            // PreKeySignalMessage: first message in a new session.
            let preKeyMessage = try PreKeySignalMessage(bytes: [UInt8](messageData))
            let decryptedBytes = try signalDecryptPreKey(
                message: preKeyMessage,
                from: address,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: NullContext()
            )
            plaintext = Data(decryptedBytes)
        case 0x02:
            // SignalMessage: message within an established session.
            let signalMessage = try SignalMessage(bytes: [UInt8](messageData))
            let decryptedBytes = try signalDecrypt(
                message: signalMessage,
                from: address,
                sessionStore: store,
                identityStore: store,
                context: NullContext()
            )
            plaintext = Data(decryptedBytes)
        default:
            throw AppError.decryptionFailed(reason: "Unknown ciphertext type byte: \(typeByte)")
        }

        return plaintext
    }

    func decryptEnvelope(_ envelope: Vync_Messaging_EncryptedEnvelope) async throws -> Data {
        return try await decrypt(
            ciphertext: envelope.ciphertext,
            from: envelope.senderID,
            senderDevice: envelope.senderDevice
        )
    }

    // MARK: - Session Maintenance

    func resetSession(with userId: String, deviceId: Int32) throws {
        let address = try ProtocolAddress(name: userId, deviceId: UInt32(deviceId))
        try store.sessionStore.deleteSession(for: address)
        SanchrLogger.crypto.info("Reset session with \(userId.prefix(8))... device \(deviceId)")
    }

    // MARK: - Identity Verification

    func safetyNumber(for userId: String, deviceId: Int32) throws -> String {
        let address = try ProtocolAddress(name: userId, deviceId: UInt32(deviceId))
        let localIdentity = try store.identityStore.identityKeyPair(context: NullContext())
            .identityKey
        guard
            let remoteIdentity = try store.identityStore.identity(
                for: address, context: NullContext())
        else {
            throw AppError.sessionNotEstablished
        }

        let fingerprint = try NumericFingerprintGenerator(iterations: 5200).create(
            version: 2,
            localIdentifier: Data(store.userId.utf8),
            localKey: localIdentity.publicKey,
            remoteIdentifier: Data(userId.utf8),
            remoteKey: remoteIdentity.publicKey
        )

        return fingerprint.displayable.formatted
    }

    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data {
        let address = try ProtocolAddress(name: userId, deviceId: UInt32(deviceId))
        let localIdentity = try store.identityStore.identityKeyPair(context: NullContext())
            .identityKey
        guard
            let remoteIdentity = try store.identityStore.identity(
                for: address, context: NullContext())
        else {
            throw AppError.sessionNotEstablished
        }

        let fingerprint = try NumericFingerprintGenerator(iterations: 5200).create(
            version: 2,
            localIdentifier: Data(store.userId.utf8),
            localKey: localIdentity.publicKey,
            remoteIdentifier: Data(userId.utf8),
            remoteKey: remoteIdentity.publicKey
        )

        return fingerprint.scannable.encoding
    }

    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool {
        let localScannable = try scannableFingerprint(for: userId, deviceId: deviceId)
        let localFingerprint = ScannableFingerprint(encoding: localScannable)
        return try localFingerprint.compare(againstEncoding: scannedData)
    }

    func markIdentityVerified(userId: String) {
        store.identityStore.markIdentityVerified(userId: userId)
    }

    func isIdentityVerified(userId: String) -> Bool {
        store.identityStore.isIdentityVerified(userId: userId)
    }

    // MARK: - Diagnostics

    /// Extracts the real gRPC status code and message from an error.
    /// `GRPCStatus` doesn't conform to `CustomNSError`, so `localizedDescription`
    /// always shows "error 1" — hiding the actual status code entirely.
    static func detailedError(_ error: Error) -> String {
        if let status = error as? GRPCStatus {
            return "gRPC \(status.code) (\(status.code.rawValue)): \(status.message ?? "no message")"
        }
        let nsError = error as NSError
        if nsError.domain == "io.grpc",
           let statusCode = GRPCStatus.Code(rawValue: nsError.code) {
            return "gRPC \(statusCode) (\(nsError.code)): \(nsError.localizedDescription)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }
}
