import Foundation
import XCTest

@testable import Sanchr

/// A vault that failed to load is not an empty vault, and one row that
/// cannot be decrypted must not hide the others.
final class VaultLoadFailureTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testAFailedFirstLoadShowsAnErrorNotTheEmptyState() throws {
        let view = try source("Features/Vault/Presentation/VaultView.swift")
        let failed = try XCTUnwrap(view.range(of: "} else if viewModel.items.isEmpty, let error = viewModel.errorMessage {"))
        let empty = try XCTUnwrap(view.range(of: "} else if viewModel.filteredItems.isEmpty {"))
        XCTAssertLessThan(failed.lowerBound, empty.lowerBound, "the failure branch must be checked before the empty one")
        XCTAssertTrue(view.contains("Button(\"Try again\")"))
    }

    func testAnUndecryptableRowIsSkippedNotFatal() throws {
        let useCases = try source("Features/Vault/Domain/VaultUseCases.swift")
        let loop = try XCTUnwrap(useCases.range(of: "for protoItem in response.items {"))
        let body = String(useCases[loop.upperBound...].prefix(700))
        XCTAssertTrue(body.contains("do {"))
        XCTAssertTrue(body.contains("} catch {"))
        XCTAssertTrue(body.contains("undecryptable += 1"))
    }
}
