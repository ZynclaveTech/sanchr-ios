import Foundation
import GRPC
import XCTest
@testable import Sanchr
@testable import SanchrShared

/// No screen shows "GRPC.GRPCStatus error N" any more.
final class UserFacingErrorTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testAGRPCStatusDescribesItselfInWords() {
        let unavailable = GRPCStatus(code: .unavailable, message: nil)
        XCTAssertEqual(unavailable.localizedDescription, UserFacingError.offline)
        XCTAssertFalse(GRPCStatus(code: .internalError, message: nil).localizedDescription.contains("GRPCStatus"))
        XCTAssertFalse(GRPCStatus(code: .unknown, message: "boom").localizedDescription.contains("error 2"))
        XCTAssertEqual(UserFacingError.message(for: GRPCStatus(code: .resourceExhausted, message: nil)), "Too many attempts. Wait a few minutes and try again.")
    }

    func testNetworkAndUnknownErrorsReadAsSentences() {
        XCTAssertEqual(UserFacingError.message(for: URLError(.notConnectedToInternet)), UserFacingError.offline)
        XCTAssertEqual(UserFacingError.message(for: URLError(.timedOut)), UserFacingError.timeout)
        struct Opaque: Error {}
        XCTAssertEqual(UserFacingError.message(for: Opaque()), UserFacingError.generic)
        XCTAssertEqual(UserFacingError.message(for: AppError.mediaExpired), AppError.mediaExpired.errorDescription)
    }

    @MainActor
    func testSignInKeepsItsOwnReadingOfAuthStatuses() {
        XCTAssertEqual(AuthViewModel.userMessage(for: GRPCStatus(code: .unauthenticated, message: nil)),
                       "That code isn't right or has expired. Check the message and try again.")
        XCTAssertEqual(AuthViewModel.userMessage(for: GRPCStatus(code: .unavailable, message: nil)), UserFacingError.offline)
    }

    func testNoScreenAssignsARawDescriptionToTheUser() throws {
        let features = Self.root.appendingPathComponent("Features")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("= error.localizedDescription") && !line.contains("SanchrLogger") {
                XCTFail("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
}
