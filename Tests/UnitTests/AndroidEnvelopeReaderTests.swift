import LibSignalClient
import XCTest
import SanchrShared

/// Reading the envelope Android sends.
///
/// "Android" here is an in-memory libsignal peer doing what the Android app
/// does on send: pad the payload, encrypt it for the session, and wrap it in
/// a sealed-sender envelope under a certificate the server signed. "Me" is
/// another in-memory store, read through the same `AndroidEnvelopeReader` the
/// app uses.
final class AndroidEnvelopeReaderTests: XCTestCase {
    private let context: StoreContext = LibSignalClient.NullContext()
    private var me: InMemorySignalProtocolStore!
    private var myIdentity: IdentityKeyPair!
    private var myAddress: ProtocolAddress!
    private var trustRoot: PrivateKey!
    private var serverKey: PrivateKey!
    private var serverCertificate: ServerCertificate!
    private var nextKeyId: UInt32 = 100
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        myIdentity = IdentityKeyPair.generate()
        me = InMemorySignalProtocolStore(identity: myIdentity, registrationId: 4242)
        myAddress = try ProtocolAddress(name: "me", deviceId: 1)
        trustRoot = PrivateKey.generate()
        serverKey = PrivateKey.generate()
        serverCertificate = try ServerCertificate(keyId: 1, publicKey: serverKey.publicKey, trustRoot: trustRoot)
    }

    // MARK: - An Android peer

    private final class AndroidPeer {
        let userId: String
        let deviceId: UInt32
        let identity = IdentityKeyPair.generate()
        let store: InMemorySignalProtocolStore
        var address: ProtocolAddress { try! ProtocolAddress(name: userId, deviceId: deviceId) }

        init(_ userId: String, deviceId: UInt32 = 1) {
            self.userId = userId
            self.deviceId = deviceId
            self.store = InMemorySignalProtocolStore(identity: identity, registrationId: 1234)
        }
    }

    /// A fresh bundle of my keys, as fetching one from the server would give.
    private func myBundle() throws -> PreKeyBundle {
        let (oneTimeId, signedId, kyberId) = (nextKeyId, nextKeyId + 1, nextKeyId + 2)
        nextKeyId += 3
        let oneTime = PrivateKey.generate()
        let signed = PrivateKey.generate()
        let kyber = KEMKeyPair.generate()
        let signedSignature = myIdentity.privateKey.generateSignature(message: signed.publicKey.serialize())
        let kyberSignature = myIdentity.privateKey.generateSignature(message: kyber.publicKey.serialize())
        let stamp = UInt64(now.timeIntervalSince1970 * 1000)
        try me.storePreKey(PreKeyRecord(id: oneTimeId, privateKey: oneTime), id: oneTimeId, context: context)
        try me.storeSignedPreKey(
            SignedPreKeyRecord(id: signedId, timestamp: stamp, privateKey: signed, signature: signedSignature),
            id: signedId, context: context)
        try me.storeKyberPreKey(
            KyberPreKeyRecord(id: kyberId, timestamp: stamp, keyPair: kyber, signature: kyberSignature),
            id: kyberId, context: context)
        return try PreKeyBundle(
            registrationId: 4242, deviceId: 1,
            prekeyId: oneTimeId, prekey: oneTime.publicKey,
            signedPrekeyId: signedId, signedPrekey: signed.publicKey, signedPrekeySignature: signedSignature,
            identity: myIdentity.identityKey,
            kyberPrekeyId: kyberId, kyberPrekey: kyber.publicKey, kyberPrekeySignature: kyberSignature)
    }

    private func startSession(_ peer: AndroidPeer) throws {
        try processPreKeyBundle(
            try myBundle(), for: myAddress, sessionStore: peer.store, identityStore: peer.store, context: context)
    }

    private func certificate(
        for peer: AndroidPeer,
        expires: Date? = nil,
        expiryInSeconds: Bool = false,
        signedBy signer: (certificate: ServerCertificate, key: PrivateKey)? = nil
    ) throws -> SenderCertificate {
        let expiry = (expires ?? now.addingTimeInterval(86_400)).timeIntervalSince1970
        return try SenderCertificate(
            sender: try SealedSenderAddress(e164: nil, uuidString: peer.userId, deviceId: peer.deviceId),
            publicKey: peer.identity.publicKey,
            expiration: UInt64(expiryInSeconds ? expiry : expiry * 1000),
            signerCertificate: signer?.certificate ?? serverCertificate,
            signerKey: signer?.key ?? serverKey)
    }

    /// What Android puts on the wire for the sealed path.
    private func sealedEnvelope(
        from peer: AndroidPeer,
        _ text: String,
        certificate: SenderCertificate? = nil
    ) throws -> Data {
        let message = try signalEncrypt(
            message: MessagePadding.pad(Data(text.utf8)), for: myAddress,
            sessionStore: peer.store, identityStore: peer.store, context: context)
        let content = try UnidentifiedSenderMessageContent(
            message, from: try certificate ?? self.certificate(for: peer), contentHint: .default, groupId: [])
        return try sealedSenderEncrypt(content, for: myAddress, identityStore: peer.store, context: context)
    }

    private func open(_ envelope: Data, at receivedAt: Date? = nil) throws -> SealedDecryptResult {
        try AndroidEnvelopeReader.openSealedSender(
            envelope, trustRoot: trustRoot.publicKey, receivedAt: receivedAt ?? now, stores: me)
    }

    /// I reply, and the peer reads it — which is what moves their next message
    /// off first-message framing.
    private func reply(to peer: AndroidPeer) throws {
        let reply = try signalEncrypt(
            message: Data("reply".utf8), for: peer.address, sessionStore: me, identityStore: me, context: context)
        XCTAssertEqual(reply.messageType, CiphertextMessage.MessageType.whisper)
        _ = try signalDecrypt(
            message: try SignalMessage(bytes: reply.serialize()), from: myAddress,
            sessionStore: peer.store, identityStore: peer.store, context: context)
    }

    // MARK: - Telling the formats apart

    func testTheFirstByteSaysWhichEnvelopeItIs() {
        XCTAssertEqual(EnvelopeFormat(of: Data([0x01, 0x33])), .typed)
        XCTAssertEqual(EnvelopeFormat(of: Data([0x02, 0x33])), .typed)
        XCTAssertEqual(EnvelopeFormat(of: Data([0x11, 0x0a])), .sealedSender)
        XCTAssertEqual(EnvelopeFormat(of: Data([0x22, 0x0a])), .sealedSender)
        XCTAssertEqual(EnvelopeFormat(of: Data([0x33, 0x0a])), .bareSignal)
        XCTAssertEqual(EnvelopeFormat(of: Data([0x44, 0x0a])), .bareSignal)
    }

    func testWhatAndroidSendsIsRecognisedAsSealedSender() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        XCTAssertEqual(EnvelopeFormat(of: try sealedEnvelope(from: alice, "hi")), .sealedSender)
    }

    // MARK: - Sealed sender

    func testAFirstMessageIsReadAndAttributedByItsCertificate() throws {
        let alice = AndroidPeer("alice", deviceId: 3)
        try startSession(alice)

        let opened = try open(try sealedEnvelope(from: alice, "hello from android"))

        XCTAssertEqual(opened.senderUserId, "alice")
        XCTAssertEqual(opened.senderDeviceId, 3)
        // The padding Android adds is gone.
        XCTAssertEqual(String(decoding: opened.plaintext, as: UTF8.self), "hello from android")
        XCTAssertNotNil(try me.loadSession(for: alice.address, context: context))
    }

    func testALaterMessageIsRead() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        _ = try open(try sealedEnvelope(from: alice, "one"))
        try reply(to: alice)

        let opened = try open(try sealedEnvelope(from: alice, "two"))

        XCTAssertEqual(String(decoding: opened.plaintext, as: UTF8.self), "two")
        XCTAssertEqual(opened.senderUserId, "alice")
    }

    /// The sender is in the certificate, so nothing is tried against anyone
    /// else's session and nobody else's session is touched.
    func testAStrangersFirstMessageLeavesExistingContactsAlone() throws {
        let carol = AndroidPeer("carol")
        try startSession(carol)
        _ = try open(try sealedEnvelope(from: carol, "hi"))
        let carolBefore = try XCTUnwrap(try me.loadSession(for: carol.address, context: context)).serialize()
        let dave = AndroidPeer("dave")
        try startSession(dave)

        let opened = try open(try sealedEnvelope(from: dave, "I'm new"))

        XCTAssertEqual(opened.senderUserId, "dave")
        XCTAssertEqual(try XCTUnwrap(try me.loadSession(for: carol.address, context: context)).serialize(), carolBefore)
        XCTAssertEqual(try me.identity(for: carol.address, context: context), carol.identity.identityKey)
    }

    func testACertificateFromAnotherAuthorityIsRefused() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        let otherRoot = PrivateKey.generate()
        let otherServer = PrivateKey.generate()
        let forged = try certificate(
            for: alice,
            signedBy: (try ServerCertificate(keyId: 1, publicKey: otherServer.publicKey, trustRoot: otherRoot), otherServer))

        XCTAssertThrowsError(try open(try sealedEnvelope(from: alice, "hi", certificate: forged))) { error in
            XCTAssertEqual(error as? AndroidEnvelopeReader.ReadError, .certificateNotValid)
        }
        XCTAssertNil(try me.loadSession(for: alice.address, context: context))
    }

    /// Someone with a valid certificate of their own cannot send under a
    /// certificate naming someone else: the envelope is bound to the key that
    /// sealed it.
    func testACertificateNamingSomeoneElseIsRefused() throws {
        let carol = AndroidPeer("carol")
        let mallory = AndroidPeer("mallory")
        try startSession(mallory)

        XCTAssertThrowsError(try open(try sealedEnvelope(from: mallory, "it's carol", certificate: try certificate(for: carol))))
        XCTAssertNil(try me.loadSession(for: carol.address, context: context))
    }

    func testACertificateIsJudgedAtTheMomentOfReceiptNotNow() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        let expiry = now.addingTimeInterval(3_600)
        let envelope = try sealedEnvelope(from: alice, "queued", certificate: try certificate(for: alice, expires: expiry))

        // Received while the certificate was good, read long after: still read.
        XCTAssertNoThrow(try open(envelope, at: now))

        // Received after it had lapsed: refused.
        let bob = AndroidPeer("bob")
        try startSession(bob)
        let late = try sealedEnvelope(from: bob, "late", certificate: try certificate(for: bob, expires: expiry))
        XCTAssertThrowsError(try open(late, at: expiry.addingTimeInterval(60))) { error in
            XCTAssertEqual(error as? AndroidEnvelopeReader.ReadError, .certificateNotValid)
        }
    }

    /// What the server actually issues. libsignal reads the expiry as
    /// milliseconds, the server writes seconds, and every test here built its
    /// certificates the way libsignal expects, so none of them noticed that
    /// no real Android message could be read.
    func testACertificateWhoseExpiryIsWrittenInSecondsIsRead() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        let good = try certificate(for: alice, expires: now.addingTimeInterval(86_400), expiryInSeconds: true)

        let opened = try open(try sealedEnvelope(from: alice, "from a real server", certificate: good), at: now)

        XCTAssertEqual(String(decoding: opened.plaintext, as: UTF8.self), "from a real server")
    }

    func testACertificateInSecondsThatHasLapsedIsStillRefused() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        let expiry = now.addingTimeInterval(3_600)
        let lapsed = try certificate(for: alice, expires: expiry, expiryInSeconds: true)

        XCTAssertThrowsError(
            try open(try sealedEnvelope(from: alice, "late", certificate: lapsed), at: expiry.addingTimeInterval(60))
        ) { error in
            XCTAssertEqual(error as? AndroidEnvelopeReader.ReadError, .certificateNotValid)
        }
    }

    func testAnExpiryIsReadInWhicheverUnitItWasWritten() {
        XCTAssertEqual(AndroidEnvelopeReader.expiryInMilliseconds(1_791_000_000), 1_791_000_000_000)
        XCTAssertEqual(AndroidEnvelopeReader.expiryInMilliseconds(1_791_000_000_000), 1_791_000_000_000)
    }

    func testATamperedEnvelopeIsRefused() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        var envelope = try sealedEnvelope(from: alice, "hi")
        envelope[envelope.count / 2] ^= 0xFF

        XCTAssertThrowsError(try open(envelope))
    }

    /// The sender is known by this point, so a lost session can be repaired
    /// with that one contact.
    func testALaterMessageToASessionThisDeviceLostSaysWhoSentIt() throws {
        let alice = AndroidPeer("alice", deviceId: 2)
        try startSession(alice)
        _ = try open(try sealedEnvelope(from: alice, "one"))
        try reply(to: alice)
        let later = try sealedEnvelope(from: alice, "two")
        // As after a reinstall here: her session is gone.
        me = InMemorySignalProtocolStore(identity: myIdentity, registrationId: 4242)

        XCTAssertThrowsError(try open(later)) { error in
            XCTAssertEqual(
                error as? AndroidEnvelopeReader.ReadError,
                .sessionLost(senderUserId: "alice", senderDeviceId: 2))
        }
    }

    /// Only a failure that is about the session starts a re-key. A store that
    /// cannot be read fails every message, and must not cost good sessions.
    func testOnlyFailuresAboutTheSessionCountAsLosingIt() {
        for lost in [
            SignalError.sessionNotFound("x"), .invalidSession("x"), .invalidMessage("x"),
        ] {
            XCTAssertTrue(AndroidEnvelopeReader.meansSessionLost(lost), "\(lost)")
        }
        for other in [
            SignalError.duplicatedMessage("x"), .untrustedIdentity("x"), .callbackError("x"),
            .internalError("x"), .invalidState("x"), .protobufError("x"), .invalidKey("x"),
            .unrecognizedMessageVersion("x"),
        ] {
            XCTAssertFalse(AndroidEnvelopeReader.meansSessionLost(other), "\(other)")
        }
        XCTAssertFalse(AndroidEnvelopeReader.meansSessionLost(CocoaError(.fileReadNoPermission)))
    }

    /// A replay is a replay, not a lost session.
    func testAReplayedLaterMessageIsADuplicateNotALostSession() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        _ = try open(try sealedEnvelope(from: alice, "one"))
        try reply(to: alice)
        let later = try sealedEnvelope(from: alice, "two")
        _ = try open(later)

        XCTAssertThrowsError(try open(later)) { error in
            guard case SignalError.duplicatedMessage = error else {
                return XCTFail("expected a duplicate, got \(error)")
            }
        }
    }

    /// A certificate that does not validate names nobody worth repairing with.
    func testAnInvalidCertificateIsNeverReportedAsALostSession() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        _ = try open(try sealedEnvelope(from: alice, "one"))
        try reply(to: alice)
        let otherRoot = PrivateKey.generate()
        let otherServer = PrivateKey.generate()
        let forged = try certificate(
            for: alice,
            signedBy: (try ServerCertificate(keyId: 1, publicKey: otherServer.publicKey, trustRoot: otherRoot), otherServer))
        let later = try sealedEnvelope(from: alice, "two", certificate: forged)
        me = InMemorySignalProtocolStore(identity: myIdentity, registrationId: 4242)

        XCTAssertThrowsError(try open(later)) { error in
            XCTAssertEqual(error as? AndroidEnvelopeReader.ReadError, .certificateNotValid)
        }
    }

    // MARK: - A bare Signal message with a named sender

    func testABareSignalMessageIsReadFirstAndLater() throws {
        let alice = AndroidPeer("alice")
        try startSession(alice)
        func bare(_ text: String) throws -> Data {
            Data(
                try signalEncrypt(
                    message: MessagePadding.pad(Data(text.utf8)), for: myAddress,
                    sessionStore: alice.store, identityStore: alice.store, context: context
                ).serialize())
        }

        let first = try bare("one")
        XCTAssertEqual(EnvelopeFormat(of: first), .bareSignal)
        XCTAssertEqual(
            String(decoding: try AndroidEnvelopeReader.openBareSignal(first, from: alice.address, stores: me), as: UTF8.self),
            "one")
        try reply(to: alice)
        XCTAssertEqual(
            String(decoding: try AndroidEnvelopeReader.openBareSignal(try bare("two"), from: alice.address, stores: me), as: UTF8.self),
            "two")
    }

    // MARK: - Padding

    func testPaddingComesOffExactly() throws {
        for length in [0, 1, 158, 159, 160, 161, 500] {
            let data = Data((0..<length).map { UInt8($0 % 251) })
            let padded = MessagePadding.pad(data)
            XCTAssertEqual(padded.count % 160, 0, "length \(length)")
            XCTAssertGreaterThan(padded.count, data.count)
            XCTAssertEqual(try MessagePadding.strip(padded), data, "length \(length)")
        }
    }

    /// A payload that ends in zeros keeps them: only the padding's own are removed.
    func testTrailingZerosInThePayloadSurvive() throws {
        let data = Data([0x7b, 0x00, 0x00])
        XCTAssertEqual(try MessagePadding.strip(MessagePadding.pad(data)), data)
    }

    func testAPlaintextWithNoSentinelIsRefusedRatherThanGuessedAt() {
        XCTAssertThrowsError(try MessagePadding.strip(Data("{\"v\":1}".utf8))) { error in
            XCTAssertEqual(error as? MessagePadding.PaddingError, .missingSentinel)
        }
        XCTAssertThrowsError(try MessagePadding.strip(Data()))
        XCTAssertThrowsError(try MessagePadding.strip(Data(count: 8)))
    }
}
