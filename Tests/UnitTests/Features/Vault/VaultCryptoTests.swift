import XCTest
import CryptoKit
import SanchrShared
@testable import Sanchr

final class VaultCryptoTests: XCTestCase {

    // MARK: - Vault HKDF derivation

    func test_deriveVaultAccessKeyManual_isDeterministic() {
        let derivation = MediaKeyDerivation()
        let dls = Data(repeating: 0x01, count: 32)
        let salt = Data(repeating: 0x02, count: 32)
        let vaultItemId = "5f3e1b7c-1234-4abc-9def-0123456789ab"

        let first = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: vaultItemId
        )
        let second = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: vaultItemId
        )

        XCTAssertEqual(first, second, "same inputs must produce the same key")
        XCTAssertEqual(first.count, 32, "key must be 32 bytes")
    }

    func test_deriveVaultAccessKeyManual_differsByVaultItemId() {
        let derivation = MediaKeyDerivation()
        let dls = Data(repeating: 0x01, count: 32)
        let salt = Data(repeating: 0x02, count: 32)

        let a = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: "item-a"
        )
        let b = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: "item-b"
        )

        XCTAssertNotEqual(a, b, "different vault_item_ids must produce different keys")
    }

    func test_deriveVaultAccessKeyFromMessage_isDeterministic() {
        let derivation = MediaKeyDerivation()
        let mediaKey = Data(repeating: 0xAA, count: 32)
        let dls = Data(repeating: 0x01, count: 32)
        let vaultItemId = "5f3e1b7c-1234-4abc-9def-0123456789ab"

        let first = derivation.deriveVaultAccessKeyFromMessage(
            mediaKey: mediaKey,
            deviceSecret: dls,
            vaultItemId: vaultItemId
        )
        let second = derivation.deriveVaultAccessKeyFromMessage(
            mediaKey: mediaKey,
            deviceSecret: dls,
            vaultItemId: vaultItemId
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
    }

    func test_manualAndFromMessage_produceDifferentKeys() {
        let derivation = MediaKeyDerivation()
        let dls = Data(repeating: 0x01, count: 32)
        let vaultItemId = "same-item"

        // Manual uses (ikm=dls, salt=random). Simulate with a 32-byte "salt"
        // that coincidentally equals mediaKey to prove the labels are what
        // provide domain separation, not the inputs.
        let collidingBytes = Data(repeating: 0xBB, count: 32)

        let manual = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: collidingBytes,
            vaultItemId: vaultItemId
        )
        let fromMessage = derivation.deriveVaultAccessKeyFromMessage(
            mediaKey: collidingBytes,
            deviceSecret: dls,
            vaultItemId: vaultItemId
        )

        XCTAssertNotEqual(
            manual, fromMessage,
            "the two HKDF labels must domain-separate even when ikm/salt bytes collide"
        )
    }
}
