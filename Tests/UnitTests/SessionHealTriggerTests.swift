import LibSignalClient
import XCTest
import SanchrShared
@testable import Sanchr

/// A heal re-keys with every contact. It must follow evidence of a lost
/// session and nothing else, and must not run again and again.
final class SessionHealTriggerTests: XCTestCase {

    // MARK: - What sets it off

    /// A message from inside an established session that no session here
    /// authenticates: someone is encrypting to a session this device lost.
    func testAMessageNoSessionCanReadIsEvidenceOfAStaleSession() {
        XCTAssertTrue(
            MessageRepositoryImpl.shouldHealAfterUndeliverable(TypedEnvelopeOpener.OpenError.noSessionAuthenticates))
    }

    /// Any registered user can send these. None of them says a session was lost.
    func testWhatAStrangerCanSendDoesNotSetOffAHeal() {
        let senderControlled: [Error] = [
            TypedEnvelopeOpener.OpenError.senderNotVouchedFor,
            TypedEnvelopeOpener.OpenError.senderNotDeclared,
            TypedEnvelopeOpener.OpenError.unknownType,
            AndroidEnvelopeReader.ReadError.certificateNotValid,
            AndroidEnvelopeReader.ReadError.senderMismatch,
            SignalError.invalidMessage("garbage"),
            SignalError.invalidMessage("reused base key"),
            SignalError.duplicatedMessage("replay"),
            AppError.decryptionFailed(reason: "Empty sealed ciphertext"),
            URLError(.notConnectedToInternet),
        ]
        for error in senderControlled {
            XCTAssertFalse(MessageRepositoryImpl.shouldHealAfterUndeliverable(error), "\(error)")
        }
    }

    // MARK: - Who

    /// Android's envelope says who sent it, so only they are re-keyed.
    func testALostSessionWithANamedSenderIsRepairedWithThatSenderAlone() {
        let error = AndroidEnvelopeReader.ReadError.sessionLost(senderUserId: "alice", senderDeviceId: 2)

        XCTAssertEqual(MessageRepositoryImpl.peerToHealAfterUndeliverable(error), "alice")
        // And it does not also set off the heal of everyone.
        XCTAssertFalse(MessageRepositoryImpl.shouldHealAfterUndeliverable(error))
    }

    func testNothingElseNamesAPeerToRepairWith() {
        let others: [Error] = [
            AndroidEnvelopeReader.ReadError.certificateNotValid,
            AndroidEnvelopeReader.ReadError.senderMismatch,
            AndroidEnvelopeReader.ReadError.sessionLost(senderUserId: "", senderDeviceId: 1),
            TypedEnvelopeOpener.OpenError.noSessionAuthenticates,
            TypedEnvelopeOpener.OpenError.senderNotVouchedFor,
            SignalError.invalidMessage("garbage"),
        ]
        for error in others {
            XCTAssertNil(MessageRepositoryImpl.peerToHealAfterUndeliverable(error), "\(error)")
        }
    }

    /// A valid certificate says who a sender is, not that they are someone to
    /// send this account's Profile Key to.
    func testATargetedHealIsOnlyForSomeoneAlreadyInAOneToOneConversation() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Shared/Repositories/MessageRepository.swift"),
            encoding: .utf8)
        let targeted = try XCTUnwrap(source.range(of: "private func healStaleSession(with peer: String) async {"))
        let body = String(source[targeted.upperBound...].prefix(260))

        XCTAssertTrue(body.contains("guard await oneToOnePeers().contains(peer) else { return }"))
        XCTAssertTrue(body.contains("guard await sessionHealLimiter.begin(peer) else { return }"))
    }

    // MARK: - How often

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
    }

    func testABurstOfUnreadableMessagesIsOnePass() async {
        let clock = Clock()
        let limiter = SessionHealLimiter(now: { clock.now })

        let first = await limiter.beginPass()
        var later: [Bool] = []
        for _ in 0..<20 { later.append(await limiter.beginPass()) }

        XCTAssertTrue(first)
        XCTAssertFalse(later.contains(true))
    }

    func testAnotherPassIsAllowedOnlyAfterTheCooldown() async {
        let clock = Clock()
        let limiter = SessionHealLimiter(passCooldown: 3_600, now: { clock.now })
        _ = await limiter.beginPass()

        clock.advance(3_599)
        let early = await limiter.beginPass()
        clock.advance(1)
        let due = await limiter.beginPass()

        XCTAssertFalse(early)
        XCTAssertTrue(due)
    }

    func testWithinAPassEachPeerIsHealedOnce() async {
        let clock = Clock()
        let limiter = SessionHealLimiter(now: { clock.now })

        let alice = await limiter.begin("alice")
        let aliceAgain = await limiter.begin("alice")
        let bob = await limiter.begin("bob")

        XCTAssertTrue(alice)
        XCTAssertFalse(aliceAgain)
        XCTAssertTrue(bob)
    }

    // MARK: - What it costs the contacts

    /// The heal starts its fresh sessions itself, without a one-time pre-key,
    /// rather than leaving them to the next encrypt, which takes one.
    func testAHealDoesNotSpendContactsOneTimePreKeys() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("SanchrShared/Crypto/SignalProtocol.swift"),
            encoding: .utf8)
        let heal = try XCTUnwrap(source.range(of: "public func resetSessions(with userId: String) async {"))
        let body = String(source[heal.upperBound...].prefix(2400))

        XCTAssertTrue(body.contains("spendingOneTimePreKey: false"))
    }
}
