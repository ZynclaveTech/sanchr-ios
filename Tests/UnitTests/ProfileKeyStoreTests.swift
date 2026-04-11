// Tests/UnitTests/ProfileKeyStoreTests.swift
import XCTest
import SanchrShared
@testable import Sanchr

final class ProfileKeyStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> ProfileKeyStore {
        ProfileKeyStore(keychain: MockKeychainService())
    }

    // MARK: - Own key tests

    func test_ownProfileKey_generates32Bytes() throws {
        let key = try makeStore().ownProfileKey()
        XCTAssertEqual(key.count, 32, "profile key must be exactly 32 bytes")
    }

    func test_ownProfileKey_isStable_acrossMultipleCalls() throws {
        let store = makeStore()
        let first  = try store.ownProfileKey()
        let second = try store.ownProfileKey()
        XCTAssertEqual(first, second, "ownProfileKey must return the same key on successive calls")
    }

    func test_ownProfileKey_isUnique_perStoreInstance() throws {
        // Each new store backed by a fresh empty MockKeychainService generates a new key.
        // Probability of accidental collision is 2^-256 — effectively impossible.
        let key1 = try makeStore().ownProfileKey()
        let key2 = try makeStore().ownProfileKey()
        XCTAssertNotEqual(key1, key2, "distinct empty keystores must produce distinct random keys")
    }

    // MARK: - Contact key tests

    func test_saveAndRead_contactProfileKey_roundtrips() throws {
        let store = makeStore()
        let key = Data(repeating: 0xCC, count: 32)
        try store.saveContactProfileKey(key, forUserId: "user-42")
        let retrieved = try store.contactProfileKey(forUserId: "user-42")
        XCTAssertEqual(retrieved, key)
    }

    func test_contactProfileKey_absentUser_returnsNil() throws {
        let retrieved = try makeStore().contactProfileKey(forUserId: "nobody")
        XCTAssertNil(retrieved)
    }

    func test_deleteContactProfileKey_removesEntry() throws {
        let store = makeStore()
        let key = Data(repeating: 0xDD, count: 32)
        try store.saveContactProfileKey(key, forUserId: "user-99")
        try store.deleteContactProfileKey(forUserId: "user-99")
        let result = try store.contactProfileKey(forUserId: "user-99")
        XCTAssertNil(result, "deleted contact key must not be retrievable")
    }
}
