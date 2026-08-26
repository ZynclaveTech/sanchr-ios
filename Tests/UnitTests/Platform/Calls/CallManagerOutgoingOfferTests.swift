// Tests/UnitTests/Platform/Calls/CallManagerOutgoingOfferTests.swift
import XCTest
import SanchrShared
@testable import Sanchr

/// Direct tests against `CallManager.buildOutgoingCallOffer` — the pure
/// helper extracted from `startCall` so multi-device fan-out can be
/// verified without standing up WebRTC or CallKit.
final class CallManagerOutgoingOfferTests: XCTestCase {

    /// Multi-device recipient: every device gets its own ciphertext, and
    /// the legacy encryptedSdpPayload mirrors the device-1 entry for
    /// pre-multi-device server compatibility.
    func test_buildOutgoingCallOffer_fansOutPerDevice() async throws {
        let signalManager = MultiDeviceFanOutSignalManager(devices: [1, 3, 7])
        let plaintext = Data("test-sdp-payload".utf8)

        let offer = try await CallManager.buildOutgoingCallOffer(
            plaintext: plaintext,
            recipientId: "bob",
            callType: "voice",
            signalManager: signalManager
        )

        XCTAssertEqual(offer.recipientID, "bob")
        XCTAssertEqual(offer.callType, "voice")
        XCTAssertEqual(offer.deviceOffers.count, 3,
            "device_offers must carry one entry per recipient device")
        XCTAssertEqual(Set(offer.deviceOffers.map(\.deviceID)), [1, 3, 7],
            "device_offers must cover every device returned by encryptCallOffers")
        let deviceOneCiphertext = offer.deviceOffers.first(where: { $0.deviceID == 1 })?.encryptedSdpPayload
        XCTAssertEqual(offer.encryptedSdpPayload, deviceOneCiphertext,
            "legacy encrypted_sdp_payload must mirror the device-1 ciphertext")
    }

    /// When device 1 is not in the recipient's device list (e.g. account was
    /// fully reprovisioned on a non-primary device), the legacy field falls
    /// back to the lowest device id.
    func test_buildOutgoingCallOffer_legacyMirrorFallsBackToLowestDeviceId() async throws {
        let signalManager = MultiDeviceFanOutSignalManager(devices: [3, 7, 11])
        let plaintext = Data("test-sdp-payload".utf8)

        let offer = try await CallManager.buildOutgoingCallOffer(
            plaintext: plaintext,
            recipientId: "bob",
            callType: "video",
            signalManager: signalManager
        )

        XCTAssertEqual(offer.callType, "video")
        XCTAssertEqual(offer.deviceOffers.count, 3)
        let deviceThreeCiphertext = offer.deviceOffers.first(where: { $0.deviceID == 3 })?.encryptedSdpPayload
        XCTAssertEqual(offer.encryptedSdpPayload, deviceThreeCiphertext,
            "no device 1 → legacy field must mirror the lowest-device-id entry")
    }

    /// A recipient with no registered devices fails fast — the call cannot
    /// be routed at all.
    func test_buildOutgoingCallOffer_emptyDeviceListThrows() async {
        let signalManager = MultiDeviceFanOutSignalManager(devices: [])

        do {
            _ = try await CallManager.buildOutgoingCallOffer(
                plaintext: Data(),
                recipientId: "ghost",
                callType: "voice",
                signalManager: signalManager
            )
            XCTFail("expected callConnectionFailed when recipient has no devices")
        } catch AppError.callConnectionFailed {
            // expected
        } catch {
            XCTFail("expected AppError.callConnectionFailed, got \(error)")
        }
    }
}

/// Identity-cipher mock that returns a controllable list of devices.
/// Tags each ciphertext with a `0xC0 <deviceId>` prefix so per-device
/// addressing is observable in test assertions.
private final class MultiDeviceFanOutSignalManager: SignalProtocolManagerProtocol, @unchecked Sendable {
    let localUserId: String = "test-local-user"
    private let devices: [Int32]

    init(devices: [Int32]) { self.devices = devices }

    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data {
        var tagged = Data([0xC0, UInt8(truncatingIfNeeded: deviceId)])
        tagged.append(plaintext)
        return tagged
    }

    func encryptCallOffers(plaintext: Data, recipientId: String) async throws -> [Sanchr_Calling_DeviceCallOffer] {
        // .map cannot be async — use a for loop.
        var out: [Sanchr_Calling_DeviceCallOffer] = []
        for deviceId in devices {
            let ct = try await encrypt(plaintext: plaintext, for: recipientId, deviceId: deviceId)
            var entry = Sanchr_Calling_DeviceCallOffer()
            entry.deviceID = deviceId
            entry.encryptedSdpPayload = ct
            out.append(entry)
        }
        return out
    }

    // Boilerplate no-ops — the fan-out tests do not exercise these.
    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data { ciphertext }
    func establishSession(with userId: String, deviceId: Int32) async throws {}
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
    func hasSession(with userId: String) -> Bool { true }
    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws -> [Sanchr_Messaging_DeviceMessage] { [] }
    func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { envelope.ciphertext }
    func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
        throw AppError.decryptionFailed(reason: "not used")
    }
    func resetSession(with userId: String, deviceId: Int32) throws {}
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
    func markIdentityVerified(userId: String) {}
    func isIdentityVerified(userId: String) -> Bool { false }
    func identityVerifiedAt(userId: String) -> Date? { nil }
    func unmarkIdentityVerified(userId: String) {}
    func hasPendingIdentityChange(userId: String) -> Bool { false }
    func acceptIdentityChange(userId: String) {}
    func localIdentityKeyData() throws -> Data { Data() }
    func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
}
