import LibSignalClient
import XCTest
import SanchrShared

/// Opening this app's own envelope when nothing outside it says who sent it.
///
/// The cases that matter are about *who* a message is from. The first message
/// of a session opens under any address it is tried against, so trying each
/// contact in turn credited a stranger's message to an existing contact and
/// replaced that contact's session with the stranger's.
final class TypedEnvelopeOpenerTests: XCTestCase {
    private let context: StoreContext = LibSignalClient.NullContext()
    private let myId = "me"
    private var me: TestStores!
    private var myAddress: ProtocolAddress!
    private var nextKeyId: UInt32 = 100
    private let lookups = Counter()

    override func setUpWithError() throws {
        me = TestStores()
        myAddress = try ProtocolAddress(name: myId, deviceId: 1)
    }

    // MARK: - Peers

    private final class Peer {
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

    private func myBundle() throws -> PreKeyBundle {
        let (oneTimeId, signedId, kyberId) = (nextKeyId, nextKeyId + 1, nextKeyId + 2)
        nextKeyId += 3
        let identity = try me.identityKeyPair(context: context)
        let oneTime = PrivateKey.generate()
        let signed = PrivateKey.generate()
        let kyber = KEMKeyPair.generate()
        let signedSignature = identity.privateKey.generateSignature(message: signed.publicKey.serialize())
        let kyberSignature = identity.privateKey.generateSignature(message: kyber.publicKey.serialize())
        try me.storePreKey(PreKeyRecord(id: oneTimeId, privateKey: oneTime), id: oneTimeId, context: context)
        try me.storeSignedPreKey(
            SignedPreKeyRecord(id: signedId, timestamp: 1, privateKey: signed, signature: signedSignature),
            id: signedId, context: context)
        try me.storeKyberPreKey(
            KyberPreKeyRecord(id: kyberId, timestamp: 1, keyPair: kyber, signature: kyberSignature),
            id: kyberId, context: context)
        return try PreKeyBundle(
            registrationId: 4242, deviceId: 1,
            prekeyId: oneTimeId, prekey: oneTime.publicKey,
            signedPrekeyId: signedId, signedPrekey: signed.publicKey, signedPrekeySignature: signedSignature,
            identity: identity.identityKey,
            kyberPrekeyId: kyberId, kyberPrekey: kyber.publicKey, kyberPrekeySignature: kyberSignature)
    }

    private func startSession(_ peer: Peer) throws {
        try processPreKeyBundle(
            try myBundle(), for: myAddress, sessionStore: peer.store, identityStore: peer.store, context: context)
    }

    /// A message framed as this app frames it. `claiming` is the sender the
    /// payload names; `nil` leaves it out, as an older build would.
    private func send(_ peer: Peer, _ text: String, claiming: (String, Int32)?? = .none) throws -> Data {
        let claim: (String, Int32)? = claiming ?? (peer.userId, Int32(peer.deviceId))
        let payload = try JSONEncoder().encode(
            InnerPayload(
                conversationId: "c", contentType: "text", content: Data(text.utf8), isSync: false,
                senderUserId: claim?.0, senderDeviceId: claim?.1))
        let message = try signalEncrypt(
            message: payload, for: myAddress, sessionStore: peer.store, identityStore: peer.store, context: context)
        var envelope = Data([message.messageType == CiphertextMessage.MessageType.preKey ? 0x01 : 0x02])
        envelope.append(Data(message.serialize()))
        return envelope
    }

    private func text(_ result: SealedDecryptResult) throws -> String {
        String(decoding: try JSONDecoder().decode(InnerPayload.self, from: result.plaintext).content, as: UTF8.self)
    }

    /// An opener whose server publishes exactly these peers' keys.
    private func opener(publishing peers: Peer..., failing: Bool = false) -> TypedEnvelopeOpener {
        let table = Dictionary(uniqueKeysWithValues: peers.map { ($0.userId, $0.identity.identityKey) })
        let lookups = self.lookups
        return TypedEnvelopeOpener(stores: me, localUserId: myId) { userId, _ in
            lookups.increment()
            if failing { throw URLError(.notConnectedToInternet) }
            return table[userId]
        }
    }

    /// Makes `peer` an existing contact: a session both ways, their key on record.
    private func befriend(_ peer: Peer) async throws {
        try startSession(peer)
        _ = try await opener(publishing: peer).open(try send(peer, "hello"))
        let reply = try signalEncrypt(
            message: Data("hi back".utf8), for: peer.address, sessionStore: me, identityStore: me, context: context)
        _ = try signalDecrypt(
            message: try SignalMessage(bytes: reply.serialize()), from: myAddress,
            sessionStore: peer.store, identityStore: peer.store, context: context)
        lookups.reset()
    }

    private func session(_ peer: Peer) throws -> Data? {
        try me.loadSession(for: peer.address, context: context)?.serialize()
    }

    private func assertNothingThrowawayIsLeft(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(me.sessionAddresses().contains { $0.name.hasPrefix("sealedscratch-") }, file: file, line: line)
        XCTAssertFalse(me.identityAddresses().contains { $0.name.hasPrefix("sealedscratch-") }, file: file, line: line)
    }

    private func assertRefused(
        _ expected: TypedEnvelopeOpener.OpenError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> SealedDecryptResult
    ) async {
        do {
            _ = try await body()
            XCTFail("opened", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TypedEnvelopeOpener.OpenError, expected, file: file, line: line)
        }
    }

    // MARK: - The first message of a session

    func testAFirstMessageFromSomeoneTheServerVouchesForIsReadAndPlacedUnderTheirAddress() async throws {
        let alice = Peer("alice", deviceId: 2)
        try startSession(alice)

        let opened = try await opener(publishing: alice).open(try send(alice, "hello"))

        XCTAssertEqual(opened.senderUserId, "alice")
        XCTAssertEqual(opened.senderDeviceId, 2)
        XCTAssertEqual(try text(opened), "hello")
        XCTAssertNotNil(try session(alice))
        XCTAssertEqual(try me.identity(for: alice.address, context: context), alice.identity.identityKey)
        assertNothingThrowawayIsLeft()
    }

    /// With no sessions at all there was nothing to try a message against, so
    /// the very first message a new install received could not be opened.
    func testAFirstMessageIsReadByADeviceWithNoSessionsAtAll() async throws {
        let alice = Peer("alice")
        try startSession(alice)
        XCTAssertTrue(me.sessionAddresses().isEmpty)

        let opened = try await opener(publishing: alice).open(try send(alice, "first ever"))

        XCTAssertEqual(opened.senderUserId, "alice")
    }

    func testAKeyAlreadyEstablishedForTheSenderNeedsNoQuestionToTheServer() async throws {
        let alice = Peer("alice")
        _ = try me.saveIdentity(alice.identity.identityKey, for: alice.address, context: context)
        try startSession(alice)

        _ = try await opener().open(try send(alice, "hello"))

        XCTAssertEqual(lookups.value, 0)
    }

    func testAStrangerCannotIntroduceThemselvesAsSomeoneElse() async throws {
        let carol = Peer("carol")
        let mallory = Peer("mallory")
        try startSession(mallory)
        let forged = try send(mallory, "it's carol, new phone", claiming: ("carol", 1))

        await assertRefused(.senderNotVouchedFor) { try await self.opener(publishing: carol, mallory).open(forged) }

        XCTAssertNil(try session(carol))
        XCTAssertNil(try me.identity(for: carol.address, context: context))
        assertNothingThrowawayIsLeft()
    }

    func testAForgedFirstMessageLeavesAnExistingContactExactlyAsTheyWere() async throws {
        let carol = Peer("carol")
        try await befriend(carol)
        let before = try session(carol)
        let mallory = Peer("mallory")
        try startSession(mallory)
        let forged = try send(mallory, "it's carol, new phone", claiming: ("carol", 1))

        await assertRefused(.senderNotVouchedFor) { try await self.opener(publishing: carol, mallory).open(forged) }

        XCTAssertEqual(try session(carol), before)
        XCTAssertEqual(try me.identity(for: carol.address, context: context), carol.identity.identityKey)
        // Not flagged as "safety number changed" either.
        XCTAssertFalse(me.hasPendingChange(for: carol.address))
        // And Carol's real messages still arrive.
        let real = try await opener().open(try send(carol, "still me"))
        XCTAssertEqual(real.senderUserId, "carol")
    }

    /// What trying each session in turn did: the message opened under whoever
    /// was tried first, and replaced them.
    func testAStrangersFirstMessageDoesNotDisturbTheContactsAlreadyHere() async throws {
        let carol = Peer("carol")
        let erin = Peer("erin")
        try await befriend(carol)
        try await befriend(erin)
        let (carolBefore, erinBefore) = (try session(carol), try session(erin))
        let dave = Peer("dave")
        try startSession(dave)

        let opened = try await opener(publishing: dave).open(try send(dave, "hi, I'm new"))

        XCTAssertEqual(opened.senderUserId, "dave")
        XCTAssertEqual(try session(carol), carolBefore)
        XCTAssertEqual(try session(erin), erinBefore)
        XCTAssertFalse(me.hasPendingChange(for: carol.address))
        XCTAssertFalse(me.hasPendingChange(for: erin.address))
    }

    func testAContactWhoseKeyChangedIsReadAndTheChangeLeftForReview() async throws {
        let before = Peer("alice")
        try await befriend(before)
        let after = Peer("alice")
        try startSession(after)

        let opened = try await opener(publishing: after).open(try send(after, "new phone"))

        XCTAssertEqual(opened.senderUserId, "alice")
        XCTAssertEqual(try me.identity(for: after.address, context: context), after.identity.identityKey)
        XCTAssertTrue(me.hasPendingChange(for: after.address))
    }

    func testAChangedKeyStillAwaitingReviewDoesNotVouchForItself() async throws {
        let before = Peer("alice")
        try await befriend(before)
        let after = Peer("alice")
        try startSession(after)
        _ = try await opener(publishing: after).open(try send(after, "new phone"))
        lookups.reset()

        // Seen again: on record, but only as a pending change — so the server
        // is asked, rather than the record being believed.
        try startSession(after)
        _ = try await opener(publishing: after).open(try send(after, "again"))

        XCTAssertEqual(lookups.value, 1)
    }

    func testAnOlderBuildsFirstMessageIsAttributedByItsKeyWhenOneContactHoldsIt() async throws {
        let alice = Peer("alice")
        try await befriend(alice)
        // The same contact starting over, from a build that names no sender.
        try startSession(alice)

        let opened = try await opener().open(try send(alice, "no sender field", claiming: .some(nil)))

        XCTAssertEqual(opened.senderUserId, "alice")
        XCTAssertEqual(lookups.value, 0)
    }

    func testAFirstMessageNamingNobodyFromAnUnknownKeyIsRefused() async throws {
        let stranger = Peer("stranger")
        try startSession(stranger)
        let anonymous = try send(stranger, "who am I", claiming: .some(nil))

        await assertRefused(.senderNotDeclared) { try await self.opener(publishing: stranger).open(anonymous) }
        assertNothingThrowawayIsLeft()
    }

    func testWhenTheServerCannotBeAskedTheClaimIsNotBelieved() async throws {
        let alice = Peer("alice")
        try startSession(alice)
        let envelope = try send(alice, "hello")

        await assertRefused(.senderNotVouchedFor) { try await self.opener(publishing: alice, failing: true).open(envelope) }

        // Asked more than once first: the message cannot be opened again.
        XCTAssertEqual(lookups.value, 3)
        XCTAssertNil(try session(alice))
        assertNothingThrowawayIsLeft()
    }

    func testAFloodOfClaimsAboutOnePersonAsksTheServerOnce() async throws {
        let carol = Peer("carol")
        let opener = opener(publishing: carol)
        for _ in 0..<5 {
            let mallory = Peer("mallory")
            try startSession(mallory)
            let forged = try send(mallory, "it's carol", claiming: ("carol", 1))
            await assertRefused(.senderNotVouchedFor) { try await opener.open(forged) }
        }

        // Each answer costs Carol a one-time pre-key.
        XCTAssertEqual(lookups.value, 1)
    }

    // MARK: - Inside an established session

    func testALaterMessageIsFoundAmongSeveralSessionsAndAttributedToTheRightOne() async throws {
        let carol = Peer("carol")
        let erin = Peer("erin")
        let alice = Peer("alice", deviceId: 3)
        for peer in [carol, erin, alice] { try await befriend(peer) }

        let envelope = try send(alice, "second message")
        XCTAssertEqual(envelope.first, 0x02)
        let opened = try await opener().open(envelope)

        XCTAssertEqual(opened.senderUserId, "alice")
        XCTAssertEqual(opened.senderDeviceId, 3)
        XCTAssertEqual(try text(opened), "second message")
        XCTAssertEqual(lookups.value, 0)
    }

    /// The session that authenticated it is the answer, whatever it says inside.
    func testTheSenderNamedInsideALaterMessageIsNotWhatAttributesIt() async throws {
        let carol = Peer("carol")
        let erin = Peer("erin")
        try await befriend(carol)
        try await befriend(erin)

        let opened = try await opener().open(try send(erin, "I am carol", claiming: ("carol", 1)))

        XCTAssertEqual(opened.senderUserId, "erin")
    }

    func testAReplayedMessageIsRecognisedAsADuplicate() async throws {
        let alice = Peer("alice")
        try await befriend(alice)
        let envelope = try send(alice, "once")
        _ = try await opener().open(envelope)

        do {
            _ = try await opener().open(envelope)
            XCTFail("a replay opened")
        } catch SignalError.duplicatedMessage {
            // expected
        }
    }

    func testALaterMessageNoSessionHereCanReadIsRefusedAndChangesNothing() async throws {
        let carol = Peer("carol")
        try await befriend(carol)
        let before = try session(carol)
        // Erin's later message, to a device that has since lost her session.
        let erin = Peer("erin")
        try await befriend(erin)
        let envelope = try send(erin, "to a session that is gone")
        me.removeSession(for: erin.address)

        await assertRefused(.noSessionAuthenticates) { try await self.opener().open(envelope) }
        XCTAssertEqual(try session(carol), before)
    }

    func testAnEnvelopeOfNeitherTypeIsRefused() async {
        await assertRefused(.unknownType) { try await self.opener().open(Data([0x00, 0x33, 0x0a])) }
    }

    func testAThrowawaySessionLeftByAKilledRunIsClearedOnTheNextStart() throws {
        let leftover = try ProtocolAddress(name: "sealedscratch-\(UUID().uuidString)", deviceId: 1)
        let alice = Peer("alice")
        try startSession(alice)
        // Any record will do to stand in for one.
        try me.storeSession(
            try XCTUnwrap(try alice.store.loadSession(for: myAddress, context: context)), for: leftover, context: context)
        _ = try me.saveIdentity(alice.identity.identityKey, for: leftover, context: context)

        _ = opener()

        assertNothingThrowawayIsLeft()
    }
}

// MARK: - Test doubles

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
}

/// Stores with the app's trust rules: a changed key is accepted on receive and
/// marked for review. Pre-keys and the identity key pair are libsignal's own
/// in-memory ones; sessions and peer identities are kept here so they can be
/// listed and removed.
private final class TestStores: TypedEnvelopeStores {
    private let keys = InMemorySignalProtocolStore(identity: IdentityKeyPair.generate(), registrationId: 4242)
    private var sessions: [ProtocolAddress: SessionRecord] = [:]
    private var identities: [ProtocolAddress: IdentityKey] = [:]
    private var pending: Set<ProtocolAddress> = []

    func hasPendingChange(for address: ProtocolAddress) -> Bool { pending.contains(address) }
    func identityAddresses() -> [ProtocolAddress] { Array(identities.keys) }

    // TypedEnvelopeStores
    func sessionAddresses() -> [ProtocolAddress] { Array(sessions.keys) }
    func removeSession(for address: ProtocolAddress) { sessions.removeValue(forKey: address) }
    func removeIdentity(for address: ProtocolAddress) {
        identities.removeValue(forKey: address)
        pending.remove(address)
    }
    func establishedAddresses(holding identity: IdentityKey) -> [ProtocolAddress] {
        identities.filter { $0.value == identity && !pending.contains($0.key) }.map(\.key)
    }

    // SessionStore
    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? { sessions[address] }
    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        addresses.compactMap { sessions[$0] }
    }
    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        sessions[address] = record
    }

    // IdentityKeyStore
    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { try keys.identityKeyPair(context: context) }
    func localRegistrationId(context: StoreContext) throws -> UInt32 { try keys.localRegistrationId(context: context) }
    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let changed = identities[address] != nil && identities[address] != identity
        identities[address] = identity
        return changed ? .replacedExisting : .newOrUnchanged
    }
    func isTrustedIdentity(
        _ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext
    ) throws -> Bool {
        if let existing = identities[address], existing != identity { pending.insert(address) }
        guard pending.contains(address) else { return true }
        if case .sending = direction { return false }
        return true
    }
    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? { identities[address] }

    // Pre-keys
    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord { try keys.loadPreKey(id: id, context: context) }
    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try keys.storePreKey(record, id: id, context: context)
    }
    func removePreKey(id: UInt32, context: StoreContext) throws { try keys.removePreKey(id: id, context: context) }
    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try keys.loadSignedPreKey(id: id, context: context)
    }
    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try keys.storeSignedPreKey(record, id: id, context: context)
    }
    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try keys.loadKyberPreKey(id: id, context: context)
    }
    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try keys.storeKyberPreKey(record, id: id, context: context)
    }
    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        try keys.markKyberPreKeyUsed(id: id, signedPreKeyId: signedPreKeyId, baseKey: baseKey, context: context)
    }
}
