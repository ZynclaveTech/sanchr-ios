import Foundation
import XCTest

@testable import Sanchr

/// The manual phone-number lookup must go through OPRF discovery like the
/// address-book sync, never upload a bare hash of the number.
final class LookupUserTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testTheRepositoryNoLongerHashesANumberDirectly() throws {
        let repository = try source("Shared/Repositories/ContactRepository.swift")
        XCTAssertFalse(repository.contains("func searchUser("))
        XCTAssertFalse(repository.contains("SHA256.hash(data: Data(normalized.utf8))"))
    }

    func testTheLookupAsksDiscoveryBeforeResolving() throws {
        let useCases = try source("Features/Contacts/Domain/ContactUseCases.swift")
        let lookup = try XCTUnwrap(useCases.range(of: "struct LookupUser: Sendable {"))
        let body = String(useCases[lookup.upperBound...].prefix(2200))
        let discover = try XCTUnwrap(body.range(of: "discoveryRepository.discoverContacts(phoneNumbers: [normalized])"))
        let resolve = try XCTUnwrap(body.range(of: "contactDataSource.syncContacts("))
        XCTAssertLessThan(discover.lowerBound, resolve.lowerBound)
        XCTAssertTrue(body.contains("guard matched.contains(normalized) else { return nil }"),
                      "only a number the server confirmed may be resolved")
    }

    func testTheLookupScreenUsesTheUseCase() throws {
        let view = try source("Features/Contacts/Presentation/PhoneNumberLookupView.swift")
        XCTAssertTrue(view.contains("ContactUseCases.LookupUser("))
        XCTAssertFalse(view.contains("searchUser(phoneNumber:"))
    }
}
