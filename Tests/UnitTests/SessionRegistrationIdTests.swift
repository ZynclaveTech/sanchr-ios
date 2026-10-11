import GRPC
import LibSignalClient
import XCTest

@testable import SanchrShared

/// The registration id this app states with each sealed send is read from the
/// session it encrypted with. The server compares it with the id that device
/// published and refuses the send when they differ, so a wrong reading here
/// would have every message refused and every session thrown away.
///
/// These run the real store and the real manager against a peer driven
/// through libsignal directly, for both ways a session comes to exist.
final class SessionRegistrationIdTests: XCTestCase {

    private static let peerRegistrationId: UInt32 = 7777
    private static let peerDeviceId: Int32 = 3

    private let context = SanchrShared.NullContext()
    private var userId: String!
    private var store: SanchrSignalStore!
    private var keyManager: SignalKeyManager!
    private var manager: SignalSessionManager!
    private var myIdentity: IdentityKeyPair!
    private var myAddress: ProtocolAddress!

    private var peerIdentity: IdentityKeyPair!
    private var peer: InMemorySignalProtocolStore!
    private var peerAddress: ProtocolAddress!

    override func setUpWithError() throws {
        userId = "regid-test-\(UUID().uuidString.lowercased())"
        store = SanchrSignalStore(userId: userId, keychainService: MockKeychainService())
        // Never called: every session here is made without the server.
        keyManager = SignalKeyManager(
            store: store, keyService: Sanchr_Keys_KeyServiceAsyncClient(channel: FakeChannel()))
        manager = SignalSessionManager(store: store, keyManager: keyManager)
        myIdentity = try keyManager.generateIdentityIfNeeded()
        myAddress = try ProtocolAddress(name: userId, deviceId: 1)

        peerIdentity = IdentityKeyPair.generate()
        peer = InMemorySignalProtocolStore(identity: peerIdentity, registrationId: Self.peerRegistrationId)
        peerAddress = try ProtocolAddress(name: "peer", deviceId: UInt32(Self.peerDeviceId))
    }

    override func tearDownWithError() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(at: base.appendingPathComponent("SignalStore/\(userId!)"))
    }

    private var stated: UInt32 {
        manager.sessionRegistrationId(with: "peer", deviceId: Self.peerDeviceId)
    }

    /// The peer's keys, as fetching their bundle from the server would give.
    private func peerBundle() throws -> PreKeyBundle {
        let oneTime = PrivateKey.generate()
        let signed = PrivateKey.generate()
        let kyber = KEMKeyPair.generate()
        let signedSignature = peerIdentity.privateKey.generateSignature(message: signed.publicKey.serialize())
        let kyberSignature = peerIdentity.privateKey.generateSignature(message: kyber.publicKey.serialize())
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        try peer.storePreKey(PreKeyRecord(id: 1, privateKey: oneTime), id: 1, context: context)
        try peer.storeSignedPreKey(
            SignedPreKeyRecord(id: 2, timestamp: stamp, privateKey: signed, signature: signedSignature),
            id: 2, context: context)
        try peer.storeKyberPreKey(
            KyberPreKeyRecord(id: 3, timestamp: stamp, keyPair: kyber, signature: kyberSignature),
            id: 3, context: context)
        return try PreKeyBundle(
            registrationId: Self.peerRegistrationId, deviceId: UInt32(Self.peerDeviceId),
            prekeyId: 1, prekey: oneTime.publicKey,
            signedPrekeyId: 2, signedPrekey: signed.publicKey, signedPrekeySignature: signedSignature,
            identity: peerIdentity.identityKey,
            kyberPrekeyId: 3, kyberPrekey: kyber.publicKey, kyberPrekeySignature: kyberSignature)
    }

    /// This app's keys, held in the real store, as the peer would fetch them.
    private func myBundle() throws -> PreKeyBundle {
        let signed = try keyManager.generateSignedPreKey()
        let oneTime = try XCTUnwrap(try keyManager.generateOneTimePreKeys(count: 1).first)
        let kyber = KEMKeyPair.generate()
        let kyberSignature = myIdentity.privateKey.generateSignature(message: kyber.publicKey.serialize())
        try store.storeKyberPreKey(
            KyberPreKeyRecord(
                id: 9, timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                keyPair: kyber, signature: kyberSignature),
            id: 9, context: context)
        return try PreKeyBundle(
            registrationId: try store.localRegistrationId(context: context), deviceId: 1,
            prekeyId: oneTime.id, prekey: try oneTime.publicKey(),
            signedPrekeyId: signed.id, signedPrekey: try signed.publicKey(),
            signedPrekeySignature: signed.signature,
            identity: myIdentity.identityKey,
            kyberPrekeyId: 9, kyberPrekey: kyber.publicKey, kyberPrekeySignature: kyberSignature)
    }

    func testWithNoSessionNothingIsStated() {
        XCTAssertEqual(stated, 0)
    }

    /// The session this app starts, from the peer's bundle.
    func testASessionThisAppStartedStatesTheIdInThePeersBundle() throws {
        try processPreKeyBundle(
            try peerBundle(), for: peerAddress, sessionStore: store, identityStore: store, context: context)

        XCTAssertEqual(stated, Self.peerRegistrationId)
    }

    /// And it is still that after the session has been used, which is when it
    /// is actually read: straight after encrypting.
    func testItIsTheSameAfterEncryptingWithTheSession() async throws {
        try processPreKeyBundle(
            try peerBundle(), for: peerAddress, sessionStore: store, identityStore: store, context: context)

        let envelope = try await manager.encrypt(
            plaintext: Data("hello".utf8), for: "peer", deviceId: Self.peerDeviceId)

        XCTAssertEqual(envelope.first, 0x01, "a first message, so no bundle was fetched to send it")
        XCTAssertEqual(stated, Self.peerRegistrationId)
    }

    /// The session the peer starts: the id is the one their first message
    /// carries, which is their own.
    func testASessionThePeerStartedStatesTheIdTheirFirstMessageCarried() async throws {
        try processPreKeyBundle(
            try myBundle(), for: myAddress, sessionStore: peer, identityStore: peer, context: context)
        let first = try signalEncrypt(
            message: Data("hi".utf8), for: myAddress, sessionStore: peer, identityStore: peer, context: context)
        XCTAssertEqual(first.messageType, .preKey)

        let plaintext = try await manager.decrypt(
            ciphertext: Data([0x01]) + Data(first.serialize()), from: "peer", senderDevice: Self.peerDeviceId)

        XCTAssertEqual(plaintext, Data("hi".utf8))
        XCTAssertEqual(stated, Self.peerRegistrationId)
    }

    func testEachDeviceHasItsOwn() throws {
        try processPreKeyBundle(
            try peerBundle(), for: peerAddress, sessionStore: store, identityStore: store, context: context)

        XCTAssertEqual(manager.sessionRegistrationId(with: "peer", deviceId: Self.peerDeviceId + 1), 0)
        XCTAssertEqual(manager.sessionRegistrationId(with: "someone-else", deviceId: Self.peerDeviceId), 0)
    }

    /// After the server says the device was set up again the session is
    /// dropped, and until a new one is made there is nothing to state.
    func testAfterAResetNothingIsStated() throws {
        try processPreKeyBundle(
            try peerBundle(), for: peerAddress, sessionStore: store, identityStore: store, context: context)

        try manager.resetSession(with: "peer", deviceId: Self.peerDeviceId)

        XCTAssertEqual(stated, 0)
    }
}
