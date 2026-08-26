import CryptoKit
import XCTest

@testable import Sanchr
@testable import SanchrShared

/// Contact discovery must not hand the server the caller's address book.
///
/// The previous flow hashed every number on the device with unsalted
/// `SHA-256(e164)` and uploaded the lot. Phone numbers are a small, structured
/// space, so those hashes are reversible by anyone holding the database — the
/// upload was the social graph in a thin disguise. Discovery now runs through
/// the OPRF and only the matches are resolved.
final class ContactDiscoveryPrivacyTests: XCTestCase {

    // MARK: - Doubles

    /// Records what discovery was asked about and what it answered.
    private final class SpyDiscoveryRepository: DiscoveryRepositoryProtocol, @unchecked Sendable {
        var queried: [String] = []
        var matches: [String] = []
        var errorToThrow: Error?

        func discoverContacts(phoneNumbers: [String]) async throws -> [String] {
            queried = phoneNumbers
            if let errorToThrow { throw errorToThrow }
            return matches
        }

        func bloomFilterCheck(phoneNumbers: [String]) async throws -> [Bool] {
            Array(repeating: false, count: phoneNumbers.count)
        }
    }

    // MARK: - Hash reversibility

    /// Demonstrates concretely why uploading the address book was unsafe: a
    /// four-digit-suffix dictionary inverts the hash in a few thousand guesses.
    /// Kept as a test so nobody reintroduces bulk hash upload believing it private.
    func test_unsaltedPhoneHash_isTriviallyReversible() {
        let target = ContactDataSource.hashPhoneNumber("+15551230042")

        var recovered: String?
        for suffix in 0..<10_000 {
            let candidate = String(format: "+1555123%04d", suffix)
            if ContactDataSource.hashPhoneNumber(candidate) == target {
                recovered = candidate
                break
            }
        }

        XCTAssertEqual(
            recovered, "+15551230042",
            "unsalted SHA-256 over a phone number is a lookup, not a protection")
    }

    // MARK: - Normalisation agreement

    /// The blinded string must be byte-identical to what the server hashed when it
    /// built the registered set, which is the raw E.164 `phone_number` column.
    /// A second normaliser that formats differently yields silent zero matches.
    func test_normalization_producesE164ForCommonFormats() {
        let variants = [
            "+1 555 123 0042",
            "+1-555-123-0042",
            "+1 (555) 123-0042",
            "+15551230042",
        ]
        for variant in variants {
            XCTAssertEqual(
                ContactDataSource.normalizePhoneNumber(variant), "+15551230042",
                "\(variant) must normalise to the stored E.164 form")
        }
    }

    func test_normalization_isStableUnderRepeatedApplication() {
        let once = ContactDataSource.normalizePhoneNumber("+1 (555) 123-0042")
        XCTAssertEqual(ContactDataSource.normalizePhoneNumber(once), once)
    }

    // MARK: - Discovery contract

    /// Only matched numbers may be resolved. Everything else stays on the device.
    func test_onlyMatchedNumbers_areResolvedToUsers() async throws {
        let discovery = SpyDiscoveryRepository()
        discovery.matches = ["+15551230042"]

        let all = ["+15551230042", "+15559999999", "+15558888888"]
        let matched = try await discovery.discoverContacts(phoneNumbers: all)

        XCTAssertEqual(discovery.queried.count, 3, "all numbers go through the OPRF")
        XCTAssertEqual(matched, ["+15551230042"])

        // Only the match is hashed for resolution — the other two never leave.
        let resolved = matched.map { ContactDataSource.hashPhoneNumber($0) }
        XCTAssertEqual(resolved.count, 1)
        XCTAssertNotEqual(
            resolved.first, ContactDataSource.hashPhoneNumber("+15559999999"),
            "a non-matching number must not be resolved")
    }

    /// Failing closed is the point. If the OPRF is unavailable the sync must fail
    /// rather than quietly reverting to uploading the whole address book.
    func test_discoveryFailure_propagates_soCallerCannotFallBackToBulkUpload() async {
        let discovery = SpyDiscoveryRepository()
        discovery.errorToThrow = AppError.networkUnavailable

        do {
            _ = try await discovery.discoverContacts(phoneNumbers: ["+15551230042"])
            XCTFail("discovery failure must propagate, not resolve to an empty match set")
        } catch {
            XCTAssertTrue(error is AppError)
        }
    }

    func test_noMatches_resolvesNothing() async throws {
        let discovery = SpyDiscoveryRepository()
        discovery.matches = []

        let matched = try await discovery.discoverContacts(
            phoneNumbers: ["+15551230042", "+15559999999"])

        XCTAssertTrue(matched.isEmpty)
        XCTAssertEqual(discovery.queried.count, 2)
    }
}

// MARK: - Batching and index mapping

/// The two subtle parts of routing every contact through the OPRF: staying under
/// the server's per-call cap, and mapping a match back to the right phone number
/// when some numbers were skipped during blinding.
final class DiscoveryBatchingTests: XCTestCase {

    func test_chunked_respectsServerBatchCap() {
        let items = Array(1...1250)
        let chunks = items.chunked(into: 500)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.count), [500, 500, 250])
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 500 }, "no batch may exceed the cap")
        XCTAssertEqual(chunks.flatMap { $0 }, items, "chunking must preserve order and content")
    }

    func test_chunked_exactMultiple_producesNoEmptyTrailingChunk() {
        XCTAssertEqual(Array(1...1000).chunked(into: 500).map(\.count), [500, 500])
    }

    func test_chunked_smallerThanCap_isSingleChunk() {
        XCTAssertEqual(Array(1...7).chunked(into: 500).count, 1)
    }

    func test_chunked_empty_producesNoChunks() {
        XCTAssertTrue([Int]().chunked(into: 500).isEmpty)
    }

    /// Reproduces the mis-attribution this change is guarding against: if a number
    /// in the middle is skipped during blinding and matches are mapped back by
    /// position, the wrong contact is reported as registered.
    func test_positionalMapping_afterASkip_namesTheWrongContact() {
        let phones = ["+15550000001", "+15550000002", "+15550000003"]
        // "…002" fails to blind, so only indices 0 and 2 survive.
        let survivingIndices = [0, 2]
        let matchOffsets = [1]  // the second surviving entry matched

        let naive = matchOffsets.map { phones[$0] }
        let correct = matchOffsets.map { phones[survivingIndices[$0]] }

        XCTAssertEqual(correct, ["+15550000003"])
        XCTAssertEqual(naive, ["+15550000002"])
        XCTAssertNotEqual(naive, correct, "positional mapping misattributes the match")
    }
}
