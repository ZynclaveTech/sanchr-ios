import LibSignalClient
import XCTest

@testable import SanchrShared

/// Trust decisions for changed identity keys.
///
/// These cover the case a malicious server would exercise: substituting its own
/// identity key for a contact. Before this suite existed, `isTrustedIdentity`
/// unconditionally returned `true`, so a substituted key was adopted silently and
/// outbound messages were encrypted to it.
final class SanchrIdentityKeyStoreTrustTests: XCTestCase {

    private var tempDir: URL!
    private var store: SanchrIdentityKeyStore!

    private let alice = "alice-user-id"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = makeStore()
    }

    override func tearDownWithError() throws {
        store = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makeStore() -> SanchrIdentityKeyStore {
        SanchrIdentityKeyStore(
            userId: "local-user",
            keychain: MockKeychainService(),
            baseDirectory: tempDir
        )
    }

    private func address(_ name: String, device: UInt32 = 1) throws -> ProtocolAddress {
        try ProtocolAddress(name: name, deviceId: device)
    }

    private func identity() -> IdentityKey {
        IdentityKeyPair.generate().identityKey
    }

    /// Establishes `key` as the trusted identity for `addr`, as first contact would.
    private func seed(_ key: IdentityKey, for addr: ProtocolAddress) throws {
        _ = try store.saveIdentity(key, for: addr, context: LibSignalClient.NullContext())
    }

    // MARK: - Trust on first use

    func test_unknownAddress_isTrustedInBothDirections() throws {
        let addr = try address(alice)
        let key = identity()

        XCTAssertTrue(
            try store.isTrustedIdentity(key, for: addr, direction: .sending, context: LibSignalClient.NullContext()))
        XCTAssertTrue(
            try store.isTrustedIdentity(key, for: addr, direction: .receiving, context: LibSignalClient.NullContext())
        )
        XCTAssertFalse(store.hasPendingIdentityChange(userId: alice))
    }

    func test_unchangedKey_staysTrustedForSending() throws {
        let addr = try address(alice)
        let key = identity()
        try seed(key, for: addr)

        XCTAssertTrue(
            try store.isTrustedIdentity(key, for: addr, direction: .sending, context: LibSignalClient.NullContext()))
        XCTAssertFalse(store.hasPendingIdentityChange(userId: alice))
    }

    // MARK: - The security case: a changed key

    func test_changedKey_blocksSending() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        let substituted = identity()

        XCTAssertFalse(
            try store.isTrustedIdentity(
                substituted, for: addr, direction: .sending, context: LibSignalClient.NullContext()),
            "A substituted identity key must not be trusted for sending"
        )
    }

    func test_changedKey_stillAllowsReceiving() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        let substituted = identity()

        XCTAssertTrue(
            try store.isTrustedIdentity(
                substituted, for: addr, direction: .receiving, context: LibSignalClient.NullContext()),
            "Receiving must keep working so the conversation is not silently broken"
        )
    }

    func test_changedKey_recordsPendingReview() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)

        _ = try store.isTrustedIdentity(
            identity(), for: addr, direction: .sending, context: LibSignalClient.NullContext())

        XCTAssertTrue(store.hasPendingIdentityChange(userId: alice))
        XCTAssertEqual(store.usersWithPendingIdentityChanges(), [alice])
    }

    func test_changedKey_revokesExistingVerification() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        store.markIdentityVerified(userId: alice)
        XCTAssertTrue(store.isIdentityVerified(userId: alice))

        _ = try store.isTrustedIdentity(
            identity(), for: addr, direction: .sending, context: LibSignalClient.NullContext())

        XCTAssertFalse(
            store.isIdentityVerified(userId: alice),
            "A key change must invalidate a prior safety-number verification"
        )
    }

    /// Regression guard for the specific way this could silently regress: once the
    /// receiving path adopts the new key there is no longer a difference to compare,
    /// so a comparison-based block would lapse and sending would resume on its own.
    func test_sendingStaysBlocked_afterReceivingPathAdoptsNewKey() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        let substituted = identity()

        // Receiving accepts, and libsignal then persists the new key.
        XCTAssertTrue(
            try store.isTrustedIdentity(
                substituted, for: addr, direction: .receiving, context: LibSignalClient.NullContext()))
        _ = try store.saveIdentity(substituted, for: addr, context: LibSignalClient.NullContext())

        XCTAssertFalse(
            try store.isTrustedIdentity(
                substituted, for: addr, direction: .sending, context: LibSignalClient.NullContext()),
            "Sending must stay blocked until the user reviews, even after the key is adopted"
        )
    }

    // MARK: - Resolving the change

    func test_acceptIdentityChange_unblocksSending() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        let substituted = identity()
        _ = try store.isTrustedIdentity(
            substituted, for: addr, direction: .sending, context: LibSignalClient.NullContext())

        store.acceptIdentityChange(userId: alice)

        XCTAssertFalse(store.hasPendingIdentityChange(userId: alice))
        XCTAssertTrue(
            try store.isTrustedIdentity(
                substituted, for: addr, direction: .sending, context: LibSignalClient.NullContext()))
    }

    func test_acceptIdentityChange_adoptsNewKeyWithoutMarkingVerified() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        let substituted = identity()
        _ = try store.isTrustedIdentity(
            substituted, for: addr, direction: .sending, context: LibSignalClient.NullContext())

        store.acceptIdentityChange(userId: alice)

        XCTAssertEqual(try store.identity(for: addr, context: LibSignalClient.NullContext()), substituted)
        XCTAssertFalse(
            store.isIdentityVerified(userId: alice),
            "Acknowledging a change is weaker than comparing safety numbers"
        )
    }

    func test_markIdentityVerified_alsoClearsPendingChange() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        let substituted = identity()
        _ = try store.isTrustedIdentity(
            substituted, for: addr, direction: .sending, context: LibSignalClient.NullContext())

        store.markIdentityVerified(userId: alice)

        XCTAssertFalse(store.hasPendingIdentityChange(userId: alice))
        XCTAssertTrue(store.isIdentityVerified(userId: alice))
        XCTAssertTrue(
            try store.isTrustedIdentity(
                substituted, for: addr, direction: .sending, context: LibSignalClient.NullContext()))
    }

    func test_acceptingOneUser_doesNotUnblockAnother() throws {
        let bob = "bob-user-id"
        let aliceAddr = try address(alice)
        let bobAddr = try address(bob)
        try seed(identity(), for: aliceAddr)
        try seed(identity(), for: bobAddr)

        _ = try store.isTrustedIdentity(
            identity(), for: aliceAddr, direction: .sending, context: LibSignalClient.NullContext())
        _ = try store.isTrustedIdentity(
            identity(), for: bobAddr, direction: .sending, context: LibSignalClient.NullContext())

        store.acceptIdentityChange(userId: alice)

        XCTAssertFalse(store.hasPendingIdentityChange(userId: alice))
        XCTAssertTrue(store.hasPendingIdentityChange(userId: bob))
    }

    func test_multipleDevices_allBlockUntilAccepted() throws {
        let d1 = try address(alice, device: 1)
        let d2 = try address(alice, device: 2)
        try seed(identity(), for: d1)
        try seed(identity(), for: d2)

        let newD1 = identity()
        let newD2 = identity()
        _ = try store.isTrustedIdentity(newD1, for: d1, direction: .sending, context: LibSignalClient.NullContext())
        _ = try store.isTrustedIdentity(newD2, for: d2, direction: .sending, context: LibSignalClient.NullContext())

        store.acceptIdentityChange(userId: alice)

        XCTAssertTrue(
            try store.isTrustedIdentity(newD1, for: d1, direction: .sending, context: LibSignalClient.NullContext()))
        XCTAssertTrue(
            try store.isTrustedIdentity(newD2, for: d2, direction: .sending, context: LibSignalClient.NullContext()))
    }

    // MARK: - Persistence

    // MARK: - Warning copy

    /// A decryption failure and a real key change previously produced the *same*
    /// "Security code changed" message, which trained users to dismiss the one
    /// warning that matters. They must stay distinguishable.
    func test_decryptionFailureAndKeyChange_haveDistinctLabels() {
        XCTAssertNotEqual(
            Message.SystemEvent.identityKeyChanged.displayLabel,
            Message.SystemEvent.decryptionFailed.displayLabel
        )
        XCTAssertEqual(
            Message.SystemEvent.identityKeyChanged.displayLabel, "Security code changed")
    }

    /// Guards the reply banner, which previously rendered `event.rawValue` and so
    /// showed raw enum names like "identityKeyChanged" to users.
    func test_everySystemEvent_hasNonIdentifierLabel() {
        let events: [Message.SystemEvent] = [
            .identityKeyChanged, .decryptionFailed, .disappearingTimerChanged, .groupCreated,
            .memberAdded, .memberRemoved, .screenshotDetected, .viewOnceConsumed, .autoVaulted,
        ]
        for event in events {
            XCTAssertNotEqual(
                event.displayLabel, event.rawValue,
                "\(event.rawValue) is rendering its raw identifier as user-facing copy")
            XCTAssertFalse(event.displayLabel.isEmpty, "\(event.rawValue) has no label")
            XCTAssertTrue(
                event.displayLabel.first?.isUppercase == true,
                "\(event.rawValue) label is not sentence-cased user-facing copy")
        }
    }

    func test_pendingChange_survivesRestart() throws {
        let addr = try address(alice)
        try seed(identity(), for: addr)
        _ = try store.isTrustedIdentity(
            identity(), for: addr, direction: .sending, context: LibSignalClient.NullContext())

        // Allow the async barrier write to land, then reopen from the same directory.
        let flushed = expectation(description: "pending changes flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flushed.fulfill() }
        wait(for: [flushed], timeout: 2.0)

        let reopened = makeStore()

        XCTAssertTrue(
            reopened.hasPendingIdentityChange(userId: alice),
            "An unreviewed change must not be forgotten by restarting the app"
        )
    }
}
