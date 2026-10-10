import GRPC
import LibSignalClient
import XCTest
@testable import SanchrShared

/// Where the answer to "which key does the server publish for this person?"
/// comes from. The call made for it costs that person nothing; a pre-key
/// bundle spends one of their one-time pre-keys, and is asked for only when
/// the server has no other way to answer.
final class PublishedIdentityKeySourceTests: XCTestCase {
    private let alice = IdentityKeyPair.generate().identityKey

    private final class Calls: @unchecked Sendable {
        var bundles = 0
    }

    func testTheKeyComesFromTheCallMadeForItAndNoBundleIsFetched() async throws {
        let calls = Calls()
        let key = try await SignalKeyManager.publishedIdentityKey(
            lookup: { Data(self.alice.serialize()) },
            bundle: { calls.bundles += 1; return self.alice })

        XCTAssertEqual(key, alice)
        // A bundle would have cost her a one-time pre-key.
        XCTAssertEqual(calls.bundles, 0)
    }

    func testAUserTheServerPublishesNoKeyForIsAnAnswer() async throws {
        let calls = Calls()
        let notFound = try await SignalKeyManager.publishedIdentityKey(
            lookup: { throw GRPCStatus(code: .notFound, message: "identity key not found") },
            bundle: { calls.bundles += 1; return self.alice })
        let empty = try await SignalKeyManager.publishedIdentityKey(
            lookup: { Data() },
            bundle: { calls.bundles += 1; return self.alice })

        XCTAssertNil(notFound)
        XCTAssertNil(empty)
        XCTAssertEqual(calls.bundles, 0)
    }

    func testAServerThatPredatesTheCallIsAskedForABundleInstead() async throws {
        let calls = Calls()
        let key = try await SignalKeyManager.publishedIdentityKey(
            lookup: { throw GRPCStatus(code: .unimplemented, message: nil) },
            bundle: { calls.bundles += 1; return self.alice })

        XCTAssertEqual(key, alice)
        XCTAssertEqual(calls.bundles, 1)
    }

    /// Falling back here would spend a pre-key every time the network blipped.
    func testATransportFailureIsNotMistakenForAnOldServer() async {
        let calls = Calls()
        for code in [GRPCStatus.Code.unavailable, .deadlineExceeded, .internalError, .unauthenticated] {
            do {
                _ = try await SignalKeyManager.publishedIdentityKey(
                    lookup: { throw GRPCStatus(code: code, message: nil) },
                    bundle: { calls.bundles += 1; return self.alice })
                XCTFail("\(code) was swallowed")
            } catch {
                XCTAssertEqual((error as? GRPCStatus)?.code, code)
            }
        }
        XCTAssertEqual(calls.bundles, 0)
    }

    func testAKeyThatIsNotAKeyIsAnErrorNotAnAnswer() async {
        do {
            _ = try await SignalKeyManager.publishedIdentityKey(
                lookup: { Data([0x01, 0x02, 0x03]) },
                bundle: { self.alice })
            XCTFail("garbage was accepted as a key")
        } catch {
            // expected
        }
    }
}
