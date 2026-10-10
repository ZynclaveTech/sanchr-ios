import LibSignalClient
import XCTest
import SanchrShared

/// Envelopes as bytes on disk, written by one platform's build of libsignal
/// and opened by the other's.
///
/// The two apps were unable to decrypt each other's messages and nothing
/// noticed: the only interop check was a nightly job that never got past its
/// first step. These run with every other unit test, in both repos.
///
/// - `Tests/fixtures/android-sealed-v1.json` is written by the Android repo's
///   `AndroidToIosFixtureTest` and opened here with `AndroidEnvelopeReader`.
/// - `Tests/fixtures/ios-typed-v1.json` is written here and opened by the
///   Android repo's `IosToAndroidFixtureTest`. To regenerate it, only when the
///   envelope this app sends changes:
///
///       TEST_RUNNER_SANCHR_WRITE_FIXTURES=1 xcodebuild test … \
///         -only-testing:SanchrTests/CrossPlatformFixtureTests
///
///   then copy it to `core/crypto/src/test/resources/interop/` in the Android
///   repo. Every key in either file was made for the fixture and exists
///   nowhere else.
final class CrossPlatformFixtureTests: XCTestCase {
    private let context: StoreContext = LibSignalClient.NullContext()

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures", isDirectory: true)
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func bytes(_ object: [String: Any], _ key: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object[key] as? String, key)), key)
    }

    private func number(_ object: [String: Any], _ key: String) throws -> UInt32 {
        UInt32(try XCTUnwrap(object[key] as? Int, key))
    }

    /// A store holding the recipient's keys from a fixture.
    private func recipientStore(_ recipient: [String: Any]) throws -> InMemorySignalProtocolStore {
        let store = InMemorySignalProtocolStore(
            identity: try IdentityKeyPair(bytes: try bytes(recipient, "identityKeyPair")),
            registrationId: try number(recipient, "registrationId"))
        try store.storePreKey(
            try PreKeyRecord(bytes: try bytes(recipient, "preKey")), id: try number(recipient, "preKeyId"), context: context)
        try store.storeSignedPreKey(
            try SignedPreKeyRecord(bytes: try bytes(recipient, "signedPreKey")),
            id: try number(recipient, "signedPreKeyId"), context: context)
        try store.storeKyberPreKey(
            try KyberPreKeyRecord(bytes: try bytes(recipient, "kyberPreKey")),
            id: try number(recipient, "kyberPreKeyId"), context: context)
        return store
    }

    // MARK: - Android → iOS

    func testAnEnvelopeWrittenByAndroidIsOpenedHere() throws {
        let fixture = try fixture("android-sealed-v1.json")
        let recipient = try XCTUnwrap(fixture["recipient"] as? [String: Any])
        let sender = try XCTUnwrap(fixture["sender"] as? [String: Any])
        let envelope = try bytes(fixture, "envelope")
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(fixture["receivedAtMs"] as? Int)) / 1000)

        XCTAssertEqual(EnvelopeFormat(of: envelope), .sealedSender)
        let opened = try AndroidEnvelopeReader.openSealedSender(
            envelope,
            trustRoot: try PublicKey(try bytes(fixture, "trustRoot")),
            receivedAt: receivedAt,
            stores: try recipientStore(recipient))

        XCTAssertEqual(opened.senderUserId, sender["userId"] as? String)
        XCTAssertEqual(Int(opened.senderDeviceId), sender["deviceId"] as? Int)
        XCTAssertEqual(opened.plaintext, try bytes(fixture, "plaintext"))

        // And what came out is a payload this app understands.
        let payload = try JSONDecoder().decode(InnerPayload.self, from: opened.plaintext)
        XCTAssertEqual(payload.conversationId, "fixture-conversation")
        XCTAssertEqual(payload.contentType, "text")
        XCTAssertEqual(String(decoding: payload.content, as: UTF8.self), "hello from android")
        XCTAssertEqual(payload.senderUserId, sender["userId"] as? String)
    }

    // MARK: - iOS → Android

    private static let typedFixtureName = "ios-typed-v1.json"
    private static let senderId = "99999999-8888-4777-8666-555555555555"
    private static let recipientId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    /// The fixture Android reads is one this app's own libsignal opens too —
    /// and, when asked, is written first.
    func testTheEnvelopeWrittenForAndroidIsOneThisAppOpens() throws {
        if ProcessInfo.processInfo.environment["SANCHR_WRITE_FIXTURES"] == "1" {
            try writeTypedFixture()
        }
        let fixture = try fixture(Self.typedFixtureName)
        let recipient = try XCTUnwrap(fixture["recipient"] as? [String: Any])
        let sender = try XCTUnwrap(fixture["sender"] as? [String: Any])
        let envelope = try bytes(fixture, "envelope")
        let store = try recipientStore(recipient)

        XCTAssertEqual(EnvelopeFormat(of: envelope), .typed)
        XCTAssertEqual(envelope.first, 0x01)
        let message = try PreKeySignalMessage(bytes: [UInt8](envelope.dropFirst()))
        // The key Android has to find published for the sender it is told.
        XCTAssertEqual(Data(message.identityKey.serialize()), try bytes(sender, "identityKey"))

        let plaintext = Data(
            try signalDecryptPreKey(
                message: message,
                from: try ProtocolAddress(
                    name: try XCTUnwrap(sender["userId"] as? String), deviceId: try number(sender, "deviceId")),
                sessionStore: store, identityStore: store, preKeyStore: store,
                signedPreKeyStore: store, kyberPreKeyStore: store, context: context))

        // Unpadded: exactly the payload.
        XCTAssertEqual(plaintext, try bytes(fixture, "plaintext"))
        let payload = try JSONDecoder().decode(InnerPayload.self, from: plaintext)
        XCTAssertEqual(payload.senderUserId, Self.senderId)
        XCTAssertEqual(payload.senderDeviceId, 3)
    }

    /// Builds an envelope the way the send path does: the real `InnerPayload`,
    /// encrypted for the session, behind the one-byte type.
    private func writeTypedFixture() throws {
        let stamp: UInt64 = 1_800_000_000_000
        let recipientIdentity = IdentityKeyPair.generate()
        let oneTime = PrivateKey.generate()
        let signed = PrivateKey.generate()
        let kyber = KEMKeyPair.generate()
        let signedSignature = recipientIdentity.privateKey.generateSignature(message: signed.publicKey.serialize())
        let kyberSignature = recipientIdentity.privateKey.generateSignature(message: kyber.publicKey.serialize())
        let bundle = try PreKeyBundle(
            registrationId: 4242, deviceId: 1,
            prekeyId: 7, prekey: oneTime.publicKey,
            signedPrekeyId: 42, signedPrekey: signed.publicKey, signedPrekeySignature: signedSignature,
            identity: recipientIdentity.identityKey,
            kyberPrekeyId: 99, kyberPrekey: kyber.publicKey, kyberPrekeySignature: kyberSignature)

        let senderIdentity = IdentityKeyPair.generate()
        let senderStore = InMemorySignalProtocolStore(identity: senderIdentity, registrationId: 1234)
        let recipientAddress = try ProtocolAddress(name: Self.recipientId, deviceId: 1)
        try processPreKeyBundle(
            bundle, for: recipientAddress, sessionStore: senderStore, identityStore: senderStore, context: context)

        let plaintext = try JSONEncoder().encode(
            InnerPayload(
                conversationId: "fixture-conversation",
                messageId: "fixture-message-2",
                contentType: "text",
                content: Data("hello from ios".utf8),
                isSync: false,
                senderUserId: Self.senderId,
                senderDeviceId: 3))
        let message = try signalEncrypt(
            message: plaintext, for: recipientAddress,
            sessionStore: senderStore, identityStore: senderStore, context: context)
        XCTAssertEqual(message.messageType, CiphertextMessage.MessageType.preKey)
        var envelope = Data([0x01])
        envelope.append(Data(message.serialize()))

        let json: [String: Any] = [
            "description": "A first message as the iOS app sends it: a type byte, then a PreKeySignalMessage. Test keys only.",
            "format": "typed",
            "sender": [
                "userId": Self.senderId,
                "deviceId": 3,
                "identityKey": Data(senderIdentity.identityKey.serialize()).base64EncodedString(),
            ],
            "recipient": [
                "userId": Self.recipientId,
                "deviceId": 1,
                "registrationId": 4242,
                "identityKeyPair": recipientIdentity.serialize().base64EncodedString(),
                "preKeyId": 7,
                "preKey": try PreKeyRecord(id: 7, privateKey: oneTime).serialize().base64EncodedString(),
                "signedPreKeyId": 42,
                "signedPreKey": try SignedPreKeyRecord(
                    id: 42, timestamp: stamp, privateKey: signed, signature: signedSignature
                ).serialize().base64EncodedString(),
                "kyberPreKeyId": 99,
                "kyberPreKey": try KyberPreKeyRecord(
                    id: 99, timestamp: stamp, keyPair: kyber, signature: kyberSignature
                ).serialize().base64EncodedString(),
            ],
            "plaintext": plaintext.base64EncodedString(),
            "envelope": envelope.base64EncodedString(),
        ]
        var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try FileManager.default.createDirectory(at: Self.fixturesDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.fixturesDirectory.appendingPathComponent(Self.typedFixtureName), options: .atomic)
    }
}
