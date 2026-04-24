import XCTest
import SwiftProtobuf
import SanchrShared

/// Verifies that hand-edited fields on the call-related generated SwiftProtobuf
/// types serialize and deserialize correctly. A field that compiles but is
/// missing from the decoder switch / traverse visitor / nameMap will fail
/// these tests by losing its value through the encode→decode cycle.
final class CallProtoRoundTripTests: XCTestCase {

    func test_callOfferEvent_callerDevice_roundTrips() throws {
        var original = Sanchr_Messaging_CallOfferEvent()
        original.callID = "call-1"
        original.callerID = "alice"
        original.callType = "voice"
        original.encryptedSdpPayload = Data([0x01, 0x02])
        original.callerDevice = 7

        let bytes = try original.serializedData()
        let decoded = try Sanchr_Messaging_CallOfferEvent(serializedBytes: bytes)

        XCTAssertEqual(decoded, original, "callerDevice must survive encode/decode")
        XCTAssertEqual(decoded.callerDevice, 7)
    }

    func test_deviceCallOffer_roundTrips() throws {
        var original = Sanchr_Calling_DeviceCallOffer()
        original.deviceID = 3
        original.encryptedSdpPayload = Data([0xAA, 0xBB, 0xCC])

        let bytes = try original.serializedData()
        let decoded = try Sanchr_Calling_DeviceCallOffer(serializedBytes: bytes)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.deviceID, 3)
        XCTAssertEqual(decoded.encryptedSdpPayload, Data([0xAA, 0xBB, 0xCC]))
    }

    func test_callOffer_deviceOffers_roundTrips() throws {
        var entryOne = Sanchr_Calling_DeviceCallOffer()
        entryOne.deviceID = 1
        entryOne.encryptedSdpPayload = Data([0x01])

        var entryTwo = Sanchr_Calling_DeviceCallOffer()
        entryTwo.deviceID = 7
        entryTwo.encryptedSdpPayload = Data([0x07])

        var original = Sanchr_Calling_CallOffer()
        original.recipientID = "bob"
        original.callType = "voice"
        original.encryptedSdpPayload = Data([0x01])  // legacy mirror
        original.deviceOffers = [entryOne, entryTwo]

        let bytes = try original.serializedData()
        let decoded = try Sanchr_Calling_CallOffer(serializedBytes: bytes)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.deviceOffers.count, 2)
        XCTAssertEqual(decoded.deviceOffers.map(\.deviceID), [1, 7])
        XCTAssertEqual(decoded.deviceOffers.map(\.encryptedSdpPayload), [Data([0x01]), Data([0x07])])
    }

    func test_callSignal_peerDevice_roundTrips_withControl() throws {
        var control = Sanchr_Calling_CallControl()
        control.action = "accepted"
        var original = Sanchr_Calling_CallSignal()
        original.callID = "call-1"
        original.control = control
        original.peerDevice = 9

        let bytes = try original.serializedData()
        let decoded = try Sanchr_Calling_CallSignal(serializedBytes: bytes)

        XCTAssertEqual(decoded, original, "peer_device must coexist with the oneof signal variant")
        XCTAssertEqual(decoded.peerDevice, 9)
        XCTAssertEqual(decoded.control.action, "accepted")
    }

    func test_callJoin_answererDevice_roundTrips() throws {
        var original = Sanchr_Calling_CallJoin()
        original.role = "callee"
        original.answererDevice = 4

        let bytes = try original.serializedData()
        let decoded = try Sanchr_Calling_CallJoin(serializedBytes: bytes)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.role, "callee")
        XCTAssertEqual(decoded.answererDevice, 4)
    }

    /// Pins the wire-format invariant that an unset Int32 field (value 0)
    /// produces a zero-byte encoding for that field — this is the basis of
    /// iOS's "0 means absent → fall back to device 1" convention. Tests both
    /// halves: (a) zero round-trips to zero, (b) the field tag does not
    /// appear in the serialized bytes at all. The fallback logic in
    /// CallManager.decryptAndValidateOffer relies specifically on absence,
    /// not just on the zero round-trip property — proto3 default semantics
    /// guarantee (a) even if the visitor guard were broken.
    func test_callerDevice_zero_isAbsentOnTheWire() throws {
        var original = Sanchr_Messaging_CallOfferEvent()
        original.callID = "call-1"
        original.callerDevice = 0  // absent

        let bytes = try original.serializedData()
        let decoded = try Sanchr_Messaging_CallOfferEvent(serializedBytes: bytes)

        XCTAssertEqual(decoded.callerDevice, 0,
            "default-valued scalar must decode back to its default — proto3 wire convention")
        // Tag for caller_device (field 7, varint wire type 0): (7 << 3) | 0 = 0x38.
        // SwiftProtobuf must omit the field entirely when it equals its default.
        XCTAssertFalse(bytes.contains(0x38),
            "callerDevice=0 must produce no wire bytes — iOS's device-1 fallback depends on this")
    }
}
