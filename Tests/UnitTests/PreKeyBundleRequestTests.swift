import LibSignalClient
import XCTest
@testable import SanchrShared
@testable import Sanchr

/// What is asked of the server for a bundle, and what is made of its answer.
///
/// Call setup opens a fresh session with each of the callee's devices before
/// every call. Each of those used to take one of the callee's one-time
/// pre-keys, so a run of calls could leave them with none.
final class PreKeyBundleRequestTests: XCTestCase {
    private let context: StoreContext = LibSignalClient.NullContext()

    func testAnOrdinaryRequestMayTakeAOneTimePreKey() {
        let request = SignalKeyManager.bundleRequest(userId: "u", deviceId: 2, withoutOneTimePreKey: false)

        XCTAssertEqual(request.userID, "u")
        XCTAssertEqual(request.deviceID, 2)
        XCTAssertFalse(request.withoutOneTimePreKey)
    }

    func testARequestForCallSetupAsksForNone() {
        let request = SignalKeyManager.bundleRequest(userId: "u", deviceId: 2, withoutOneTimePreKey: true)

        XCTAssertTrue(request.withoutOneTimePreKey)
    }

    /// The option is new. On the wire an old server must see exactly what it
    /// always saw when it is not set.
    func testTheOptionIsAbsentFromTheWireUnlessSet() throws {
        var legacy = Sanchr_Keys_GetPreKeyBundleRequest()
        legacy.userID = "u"
        legacy.deviceID = 2

        XCTAssertEqual(
            try SignalKeyManager.bundleRequest(userId: "u", deviceId: 2, withoutOneTimePreKey: false).serializedData(),
            try legacy.serializedData())
        XCTAssertNotEqual(
            try SignalKeyManager.bundleRequest(userId: "u", deviceId: 2, withoutOneTimePreKey: true).serializedData(),
            try legacy.serializedData())
    }

    // MARK: - The answer

    private func response(withOneTimePreKey: Bool) throws -> (Sanchr_Keys_PreKeyBundleResponse, IdentityKeyPair) {
        let identity = IdentityKeyPair.generate()
        let signed = PrivateKey.generate()
        let kyber = KEMKeyPair.generate()
        var response = Sanchr_Keys_PreKeyBundleResponse()
        response.identityPublicKey = Data(identity.identityKey.serialize())
        response.registrationID = 4242
        response.signedPreKey.keyID = 11
        response.signedPreKey.publicKey = Data(signed.publicKey.serialize())
        response.signedPreKey.signature = Data(identity.privateKey.generateSignature(message: signed.publicKey.serialize()))
        response.kyberPreKey.keyID = 22
        response.kyberPreKey.publicKey = Data(kyber.publicKey.serialize())
        response.kyberPreKey.signature = Data(identity.privateKey.generateSignature(message: kyber.publicKey.serialize()))
        if withOneTimePreKey {
            response.oneTimePreKey.keyID = 31
            response.oneTimePreKey.publicKey = Data(PrivateKey.generate().publicKey.serialize())
        }
        return (response, identity)
    }

    /// A bundle with no one-time pre-key is a whole bundle: a session can be
    /// started from it and a message encrypted.
    func testABundleWithoutAOneTimePreKeyStartsASession() throws {
        let (response, _) = try response(withOneTimePreKey: false)
        let bundle = try SignalKeyManager.bundle(from: response, deviceId: 1)
        let me = InMemorySignalProtocolStore()
        let peer = try ProtocolAddress(name: "peer", deviceId: 1)

        try processPreKeyBundle(bundle, for: peer, sessionStore: me, identityStore: me, context: context)
        let message = try signalEncrypt(
            message: Data("offer".utf8), for: peer, sessionStore: me, identityStore: me, context: context)

        XCTAssertEqual(message.messageType, CiphertextMessage.MessageType.preKey)
        // And it names no one-time pre-key for the other side to look up.
        XCTAssertNil(try PreKeySignalMessage(bytes: message.serialize()).preKeyId())
    }

    func testABundleWithAOneTimePreKeyUsesIt() throws {
        let (response, _) = try response(withOneTimePreKey: true)
        let bundle = try SignalKeyManager.bundle(from: response, deviceId: 1)
        let me = InMemorySignalProtocolStore()
        let peer = try ProtocolAddress(name: "peer", deviceId: 1)

        try processPreKeyBundle(bundle, for: peer, sessionStore: me, identityStore: me, context: context)
        let message = try signalEncrypt(
            message: Data("hi".utf8), for: peer, sessionStore: me, identityStore: me, context: context)

        XCTAssertEqual(try PreKeySignalMessage(bytes: message.serialize()).preKeyId(), 31)
    }

    func testAnAnswerMissingTheKeysASessionNeedsIsRefused() throws {
        var (response, _) = try response(withOneTimePreKey: true)
        response.clearKyberPreKey()

        XCTAssertThrowsError(try SignalKeyManager.bundle(from: response, deviceId: 1))
    }

    /// Call setup and the automatic session heal ask for no one-time pre-key;
    /// sending a message still may.
    func testOnlyCallSetupAndTheHealAskForNone() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("SanchrShared/Crypto/SignalProtocol.swift"),
            encoding: .utf8)
        let callPath = try XCTUnwrap(source.range(of: "public func encryptCallOffers("))
        let callBody = String(source[callPath.upperBound...].prefix(2600))

        XCTAssertTrue(callBody.contains("spendingOneTimePreKey: false"))
        XCTAssertEqual(source.components(separatedBy: "spendingOneTimePreKey: false").count - 1, 2)
        // The ordinary path — a message to someone with no session — still does.
        XCTAssertTrue(source.contains("try await establishSession(with: userId, deviceId: deviceId, spendingOneTimePreKey: true)"))
    }
}
