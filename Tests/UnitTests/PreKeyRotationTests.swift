import LibSignalClient
import XCTest
@testable import SanchrShared
@testable import Sanchr

/// Replacing the signed pre-key and Kyber pre-key on a schedule, and staying
/// correct when a rotation is interrupted part-way.
final class PreKeyRotationTests: XCTestCase {
    private let context: StoreContext = LibSignalClient.NullContext()
    private let week = PreKeyRotation.interval
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!
    private var keychain: MockKeychainService!
    private var signed: SanchrSignedPreKeyStore!
    private var kyber: SanchrKyberPreKeyStore!
    private var identity: IdentityKeyPair!
    private var server: Server!

    /// Records what was uploaded, and can be told to fail or to wait.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var _uploads: [Sanchr_Keys_KeyBundle] = []
        private var _failing = false
        private var gate: CheckedContinuation<Void, Never>?
        private var _holding = false
        private var arrived: CheckedContinuation<Void, Never>?

        var uploads: [Sanchr_Keys_KeyBundle] { lock.lock(); defer { lock.unlock() }; return _uploads }
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }

        /// Makes the next upload wait until `release()`.
        func hold() { lock.lock(); _holding = true; lock.unlock() }

        func waitForUploadToArrive() async {
            await withCheckedContinuation { notifyOnArrival($0) }
        }

        private func notifyOnArrival(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            let alreadyHere = gate != nil
            if !alreadyHere { arrived = continuation }
            lock.unlock()
            if alreadyHere { continuation.resume() }
        }

        func release() {
            lock.lock()
            let waiting = gate
            gate = nil
            _holding = false
            lock.unlock()
            waiting?.resume()
        }

        func receive(_ bundle: Sanchr_Keys_KeyBundle) async throws {
            if isHolding {
                await withCheckedContinuation { park($0) }
            }
            if failing { throw URLError(.networkConnectionLost) }
            record(bundle)
        }

        private var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return _holding }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            gate = continuation
            let waiter = arrived
            arrived = nil
            lock.unlock()
            waiter?.resume()
        }

        private func record(_ bundle: Sanchr_Keys_KeyBundle) {
            lock.lock()
            _uploads.append(bundle)
            lock.unlock()
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rotation-\(UUID().uuidString)")
        keychain = MockKeychainService()
        signed = SanchrSignedPreKeyStore(userId: "u", keychain: keychain)
        kyber = SanchrKyberPreKeyStore(userId: "u", keychain: keychain, baseDirectory: directory)
        identity = IdentityKeyPair.generate()
        server = Server()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rotation() -> PreKeyRotation {
        let identity = self.identity!
        let server = self.server!
        return PreKeyRotation(
            signedPreKeys: signed, kyberPreKeys: kyber,
            identity: { (identity, 4242) },
            upload: { try await server.receive($0) })
    }

    /// The pair registration publishes.
    @discardableResult
    private func register(at date: Date, id: UInt32 = 11) throws -> UInt32 {
        let stamp = UInt64(date.timeIntervalSince1970 * 1000)
        let signedKey = PrivateKey.generate()
        try signed.storeSignedPreKey(
            SignedPreKeyRecord(
                id: id, timestamp: stamp, privateKey: signedKey,
                signature: identity.privateKey.generateSignature(message: signedKey.publicKey.serialize())),
            id: id, context: context)
        let kyberKey = KEMKeyPair.generate()
        try kyber.storeKyberPreKey(
            KyberPreKeyRecord(
                id: id, timestamp: stamp, keyPair: kyberKey,
                signature: identity.privateKey.generateSignature(message: kyberKey.publicKey.serialize())),
            id: id, context: context)
        return id
    }

    private func holdsSigned(_ id: UInt32) -> Bool {
        (try? SanchrSignedPreKeyStore(userId: "u", keychain: keychain).loadSignedPreKey(id: id, context: context)) != nil
    }

    private func holdsKyber(_ id: UInt32) -> Bool {
        (try? SanchrKyberPreKeyStore(userId: "u", keychain: keychain, baseDirectory: directory)
            .loadKyberPreKey(id: id, context: context)) != nil
    }

    // MARK: - When

    func testAPairYoungerThanAWeekIsLeftAlone() async throws {
        try register(at: start)

        let rotated = try await rotation().rotateIfNeeded(now: start.addingTimeInterval(week - 60))

        XCTAssertFalse(rotated)
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertEqual(signed.currentSignedPreKeyId, 11)
    }

    func testBeforeRegistrationThereIsNothingToRotate() async throws {
        let rotated = try await rotation().rotateIfNeeded(now: start)

        XCTAssertFalse(rotated)
        XCTAssertTrue(server.uploads.isEmpty)
    }

    // MARK: - What is published

    func testAWeekOldPairIsReplacedByOneSignedWithTheIdentityKey() async throws {
        try register(at: start)
        let now = start.addingTimeInterval(week)

        let rotated = try await rotation().rotateIfNeeded(now: now)

        XCTAssertTrue(rotated)
        let bundle = try XCTUnwrap(server.uploads.first)
        XCTAssertEqual(server.uploads.count, 1)
        XCTAssertEqual(bundle.identityPublicKey, Data(identity.identityKey.serialize()))
        XCTAssertEqual(bundle.registrationID, 4242)
        XCTAssertNotEqual(bundle.signedPreKey.keyID, 11)
        XCTAssertEqual(bundle.signedPreKey.timestamp, Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertTrue(
            try identity.publicKey.verifySignature(
                message: bundle.signedPreKey.publicKey, signature: bundle.signedPreKey.signature))
        XCTAssertTrue(
            try identity.publicKey.verifySignature(
                message: bundle.kyberPreKey.publicKey, signature: bundle.kyberPreKey.signature))
        // The server adds to the one-time keys it holds; a rotation sends none.
        XCTAssertTrue(bundle.oneTimePreKeys.isEmpty)
    }

    func testThePublishedPairIsHeldAndBecomesCurrent() async throws {
        try register(at: start)

        try await rotation().rotateIfNeeded(now: start.addingTimeInterval(week))

        let bundle = try XCTUnwrap(server.uploads.first)
        let signedId = UInt32(bundle.signedPreKey.keyID)
        XCTAssertEqual(signed.currentSignedPreKeyId, signedId)
        XCTAssertEqual(
            Data(try signed.loadSignedPreKey(id: signedId, context: context).publicKey().serialize()),
            bundle.signedPreKey.publicKey)
        XCTAssertEqual(
            Data(try kyber.loadKyberPreKey(id: UInt32(bundle.kyberPreKey.keyID), context: context).publicKey().serialize()),
            bundle.kyberPreKey.publicKey)
        // And it survives a restart.
        XCTAssertEqual(SanchrSignedPreKeyStore(userId: "u", keychain: keychain).currentSignedPreKeyId, signedId)
        XCTAssertNil(signed.pendingRotation)
    }

    /// A peer who fetched a bundle before the rotation may still send to it.
    func testTheReplacedPairIsStillHeld() async throws {
        try register(at: start)

        try await rotation().rotateIfNeeded(now: start.addingTimeInterval(week))

        XCTAssertTrue(holdsSigned(11))
        XCTAssertTrue(holdsKyber(11))
    }

    func testTheClockRestartsFromTheNewPair() async throws {
        try register(at: start)
        let rotation = rotation()
        try await rotation.rotateIfNeeded(now: start.addingTimeInterval(week))

        let again = try await rotation.rotateIfNeeded(now: start.addingTimeInterval(week + 3_600))

        XCTAssertFalse(again)
        XCTAssertEqual(server.uploads.count, 1)
    }

    // MARK: - Interrupted

    func testAFailedUploadLeavesTheOldPairCurrentSoItIsTriedAgain() async throws {
        try register(at: start)
        server.failing = true

        do {
            try await rotation().rotateIfNeeded(now: start.addingTimeInterval(week))
            XCTFail("a failed upload was reported as a rotation")
        } catch {
            // expected
        }

        XCTAssertEqual(signed.currentSignedPreKeyId, 11)
        XCTAssertNotNil(signed.pendingRotation)
    }

    /// An upload whose reply was lost may have reached the server. The pair
    /// is kept, and the retry sends that same pair rather than making another
    /// and leaving the server handing out keys this device threw away.
    func testARetrySendsTheSamePairAndKeepsItHeldInBetween() async throws {
        try register(at: start)
        server.failing = true
        _ = try? await rotation().rotateIfNeeded(now: start.addingTimeInterval(week))
        let pending = try XCTUnwrap(signed.pendingRotation)
        XCTAssertTrue(holdsSigned(pending.signedPreKeyId))
        XCTAssertTrue(holdsKyber(pending.kyberPreKeyId))

        // After a restart, with the network back.
        server.failing = false
        signed = SanchrSignedPreKeyStore(userId: "u", keychain: keychain)
        kyber = SanchrKyberPreKeyStore(userId: "u", keychain: keychain, baseDirectory: directory)
        let rotated = try await rotation().rotateIfNeeded(now: start.addingTimeInterval(week + 86_400))

        XCTAssertTrue(rotated)
        let bundle = try XCTUnwrap(server.uploads.first)
        XCTAssertEqual(UInt32(bundle.signedPreKey.keyID), pending.signedPreKeyId)
        XCTAssertEqual(UInt32(bundle.kyberPreKey.keyID), pending.kyberPreKeyId)
        XCTAssertEqual(signed.currentSignedPreKeyId, pending.signedPreKeyId)
        XCTAssertNil(signed.pendingRotation)
        // Old, the retried pair, and nothing else.
        XCTAssertEqual(signed.heldIds().count, 2)
        XCTAssertEqual(kyber.heldIds().count, 2)
    }

    func testTwoRotationsAtOnceAreOne() async throws {
        try register(at: start)
        let rotation = rotation()
        let now = start.addingTimeInterval(week)
        server.hold()

        async let first = rotation.rotateIfNeeded(now: now)
        await server.waitForUploadToArrive()
        let second = try await rotation.rotateIfNeeded(now: now)
        server.release()
        let firstResult = try await first

        XCTAssertTrue(firstResult)
        XCTAssertFalse(second)
        XCTAssertEqual(server.uploads.count, 1)
    }

    // MARK: - Old keys

    func testAKeyIsLetGoOnlyOnceItIsPastTheGracePeriod() async throws {
        try register(at: start)
        let rotation = rotation()
        var ids: [UInt32] = [11]
        for weeks in 1...3 {
            try await rotation.rotateIfNeeded(now: start.addingTimeInterval(week * Double(weeks)))
            ids.append(UInt32(try XCTUnwrap(server.uploads.last).signedPreKey.keyID))
        }
        let kyberIds = [11] + server.uploads.map { UInt32($0.kyberPreKey.keyID) }

        // Three weeks on: the registration pair is past two weeks' grace; the
        // pair from week one is exactly at it and stays.
        XCTAssertFalse(holdsSigned(ids[0]))
        XCTAssertFalse(holdsKyber(kyberIds[0]))
        for index in 1...3 {
            XCTAssertTrue(holdsSigned(ids[index]), "signed pair \(index)")
            XCTAssertTrue(holdsKyber(kyberIds[index]), "kyber pair \(index)")
        }
        XCTAssertEqual(signed.heldIds(), ids.dropFirst().sorted())
        XCTAssertEqual(kyber.heldIds(), kyberIds.dropFirst().sorted())
    }

    /// The id is the low bits of the time, which come round again.
    func testANewPairNeverTakesAnIdAlreadyInUse() async throws {
        let now = start.addingTimeInterval(week)
        let clash = UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970)) & 0x00FF_FFFF
        try register(at: start, id: clash)

        try await rotation().rotateIfNeeded(now: now)

        let bundle = try XCTUnwrap(server.uploads.first)
        XCTAssertNotEqual(UInt32(bundle.signedPreKey.keyID), clash)
        XCTAssertNotEqual(UInt32(bundle.kyberPreKey.keyID), clash)
        XCTAssertTrue(holdsSigned(clash))
    }

    /// A key stored before held ids were tracked is found the first time it
    /// is used, so it too is let go when it is old.
    func testAKeyFromBeforeIdsWereTrackedIsTrackedOnceUsed() throws {
        try register(at: start)
        // As an install from before this change would be: keys, no list.
        try keychain.delete(forKey: "io.sanchr.signal.signed_prekey_ids.u")
        try keychain.delete(forKey: "io.sanchr.signal.kyber_prekey_ids.u")
        let oldKyber = SanchrKyberPreKeyStore(userId: "u", keychain: keychain, baseDirectory: directory)
        XCTAssertTrue(oldKyber.heldIds().isEmpty)

        _ = try oldKyber.loadKyberPreKey(id: 11, context: context)

        XCTAssertEqual(oldKyber.heldIds(), [11])
        // The current signed pre-key is always counted, list or no list.
        XCTAssertEqual(SanchrSignedPreKeyStore(userId: "u", keychain: keychain).heldIds(), [11])
    }
}
