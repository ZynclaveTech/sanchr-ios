import Foundation
import LibSignalClient

/// Which of the envelopes in use a blob of ciphertext is.
///
/// This app sends one type byte and then a plain Signal message. The Android
/// app sends libsignal's sealed-sender envelope. Until both were read here the
/// two apps could not decrypt each other's messages at all: an Android
/// envelope starts with `0x11`, and the only bytes accepted in that position
/// were `0x01` and `0x02`.
///
/// The first byte is enough to tell them apart, because every one of them
/// begins with a version or a tag and none of those collide.
public enum EnvelopeFormat: Equatable, Sendable {
    /// `0x01 || PreKeySignalMessage`, `0x02 || SignalMessage`: what this app sends.
    case typed
    /// libsignal's sealed sender, `(version << 4) | version` with version 1 or 2.
    case sealedSender
    /// A Signal message with nothing in front of it; its own version leads (3 and up).
    case bareSignal

    public init(of envelope: Data) {
        switch envelope.first ?? 0 {
        case 0x00...0x02: self = .typed
        case 0x11, 0x22: self = .sealedSender
        default: self = .bareSignal
        }
    }
}

/// libsignal's message padding: the plaintext, a `0x80` sentinel, then zeros
/// to a block boundary. Android pads everything it encrypts; this app does
/// not, so what arrives from Android has to have it taken off.
public enum MessagePadding {
    public enum PaddingError: Error, Equatable {
        case missingSentinel
    }

    /// `data || 0x80 || 0x00…` up to the next multiple of `blockSize`. Always
    /// adds at least the sentinel, so the padding is always removable.
    public static func pad(_ data: Data, blockSize: Int = 160) -> Data {
        let unpadded = data.count + 1
        let total = ((unpadded + blockSize - 1) / blockSize) * blockSize
        var out = data
        out.append(0x80)
        out.append(Data(count: total - unpadded))
        return out
    }

    /// Everything before the sentinel. A plaintext with no sentinel was not
    /// padded by this scheme, and is refused rather than passed on with its
    /// tail possibly missing.
    public static func strip(_ padded: Data) throws -> Data {
        var end = padded.endIndex
        while end > padded.startIndex, padded[padded.index(before: end)] == 0x00 {
            end = padded.index(before: end)
        }
        guard end > padded.startIndex, padded[padded.index(before: end)] == 0x80 else {
            throw PaddingError.missingSentinel
        }
        return Data(padded[padded.startIndex..<padded.index(before: end)])
    }
}

/// Opens the envelopes the Android app sends.
///
/// Kept apart from `SignalSessionManager` and written against libsignal's
/// store protocols, not the app's own stores, so it can be run against real
/// key material in a test without a keychain.
public enum AndroidEnvelopeReader {
    public typealias Stores = SessionStore & IdentityKeyStore & PreKeyStore & SignedPreKeyStore & KyberPreKeyStore

    public enum ReadError: Error, Equatable {
        /// The certificate is not signed under the trust root, or had expired
        /// by the time the message was received.
        case certificateNotValid
        /// The envelope came with a named sender, and is from someone else.
        case senderMismatch
        case unsupportedMessageType
        /// The certificate is good and names this sender, but the message is
        /// from inside a session this device does not hold: they are
        /// encrypting to a session that has been lost here.
        case sessionLost(senderUserId: String, senderDeviceId: UInt32)
    }

    /// Opens a sealed-sender envelope.
    ///
    /// The sender comes out of the certificate inside it, which the server
    /// signed and which is checked against `trustRoot`. That is the whole
    /// point of the format: there is no guessing which session it belongs to,
    /// and so none of the hazards of trying each in turn.
    ///
    /// - Parameter receivedAt: when the server took delivery. The certificate
    ///   is judged at that moment and not at "now", so a message that waited
    ///   in the queue past its sender's certificate is still read.
    public static func openSealedSender(
        _ envelope: Data,
        trustRoot: PublicKey,
        receivedAt: Date,
        stores: some Stores
    ) throws -> SealedDecryptResult {
        let context = NullContext()
        let content = try UnidentifiedSenderMessageContent(message: envelope, identityStore: stores, context: context)
        let certificate = content.senderCertificate
        let millis = UInt64(max(0, receivedAt.timeIntervalSince1970 * 1000))
        guard certificate.validate(trustRoot: trustRoot, time: millis) else {
            throw ReadError.certificateNotValid
        }

        let sender = try ProtocolAddress(name: certificate.senderUuid, deviceId: certificate.deviceId)
        let padded: Data
        do {
            padded = try decrypt(content.contents, type: content.messageType, from: sender, stores: stores)
        } catch {
            // Past this point the sender is known and vouched for, which this
            // app's own envelope never offers. If what they sent is a message
            // from inside a session and no session here opens it, say so and
            // say who: the caller can then put it right with that one contact,
            // instead of with everyone or with nobody.
            guard content.messageType == .whisper, Self.meansSessionLost(error) else { throw error }
            throw ReadError.sessionLost(senderUserId: certificate.senderUuid, senderDeviceId: certificate.deviceId)
        }
        return SealedDecryptResult(
            plaintext: try MessagePadding.strip(padded),
            senderUserId: certificate.senderUuid,
            senderDeviceId: Int32(certificate.deviceId)
        )
    }

    /// Whether a failure to open a message from inside a session says the
    /// session is gone, rather than that something else went wrong.
    ///
    /// The answer starts a re-key with the sender, so it is given only for
    /// the failures that are about the session: there is none, or none of
    /// the ones held authenticates the message. Everything else is left as
    /// it was — a replay, an identity that is not trusted, a message that
    /// does not parse, and above all a store that could not be read. A
    /// keychain that is locked makes every message fail, and that is not a
    /// reason to throw away sessions that are perfectly good.
    public static func meansSessionLost(_ error: Error) -> Bool {
        switch error {
        case SignalError.sessionNotFound, SignalError.invalidSession, SignalError.invalidMessage:
            return true
        default:
            return false
        }
    }

    /// Opens a Signal message that arrived with nothing in front of it, from a
    /// sender the server named.
    public static func openBareSignal(
        _ message: Data,
        from sender: ProtocolAddress,
        stores: some Stores
    ) throws -> Data {
        // Nothing says which kind it is, so it is read as the kind that
        // starts a session first: that parse fails cleanly on the other.
        let padded: Data
        if let first = try? PreKeySignalMessage(bytes: [UInt8](message)) {
            padded = try decryptFirst(first, from: sender, stores: stores)
        } else {
            padded = try decryptLater(try SignalMessage(bytes: [UInt8](message)), from: sender, stores: stores)
        }
        return try MessagePadding.strip(padded)
    }

    private static func decrypt(
        _ contents: Data,
        type: CiphertextMessage.MessageType,
        from sender: ProtocolAddress,
        stores: some Stores
    ) throws -> Data {
        switch type {
        case .preKey:
            return try decryptFirst(try PreKeySignalMessage(bytes: [UInt8](contents)), from: sender, stores: stores)
        case .whisper:
            return try decryptLater(try SignalMessage(bytes: [UInt8](contents)), from: sender, stores: stores)
        default:
            throw ReadError.unsupportedMessageType
        }
    }

    private static func decryptFirst(
        _ message: PreKeySignalMessage,
        from sender: ProtocolAddress,
        stores: some Stores
    ) throws -> Data {
        Data(
            try signalDecryptPreKey(
                message: message,
                from: sender,
                sessionStore: stores,
                identityStore: stores,
                preKeyStore: stores,
                signedPreKeyStore: stores,
                kyberPreKeyStore: stores,
                context: NullContext()
            )
        )
    }

    private static func decryptLater(
        _ message: SignalMessage,
        from sender: ProtocolAddress,
        stores: some Stores
    ) throws -> Data {
        Data(
            try signalDecrypt(
                message: message, from: sender, sessionStore: stores, identityStore: stores, context: NullContext())
        )
    }
}
