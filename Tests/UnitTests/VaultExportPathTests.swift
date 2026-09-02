import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Where a vault item is written when it is saved to Files.
///
/// The name is chosen by whoever sent the file, and it went straight into
/// `appendingPathComponent` — so `../` escaped the export directory, and the
/// cleanup afterwards deleted the parent of wherever it landed. The share
/// path already sanitised; the save path did not.
final class VaultExportPathTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/vault-save-TEST", isDirectory: true)

    private func item(named name: String) -> VaultItem {
        VaultItem(
            id: "i", mediaId: "m", name: name, type: .document, sizeBytes: 1,
            createdAt: Date(), updatedAt: Date()
        )
    }

    private func destination(_ name: String) -> URL? {
        VaultViewModel.exportURL(for: item(named: name), in: directory)
    }

    func testAnOrdinaryNameLandsInsideTheDirectory() throws {
        let url = try XCTUnwrap(destination("report.pdf"))
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(url.lastPathComponent, "report.pdf")
    }

    /// The attack. Every one of these must resolve inside the directory or be
    /// refused — never above it.
    func testTraversalNamesCannotEscape() {
        for name in ["../../etc/passwd", "..", "../x", "/etc/passwd", "a/../../b", "..\\..\\x"] {
            guard let url = destination(name) else { continue }
            XCTAssertTrue(
                url.path.hasPrefix(directory.path + "/"),
                "\(name) resolved to \(url.path), outside the export directory"
            )
        }
    }

    func testAnEmptyNameStillGetsAFile() throws {
        let url = try XCTUnwrap(destination(""))
        XCTAssertEqual(url.deletingLastPathComponent().path, directory.path)
        XCTAssertFalse(url.lastPathComponent.isEmpty)
    }

    /// Both save routes sanitise, and cleanup deletes only what the flow made.
    func testBothSavePathsAreSanitisedAndCleanupIsContained() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("Features/Vault/Presentation/VaultViewModel.swift"),
            encoding: .utf8
        )
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("item.name.isEmpty ? \"vault-item\" : item.name"), "raw sender name must not reach a path")
        XCTAssertTrue(code.contains("suggestedFilename: VaultSharingCoordinator.safeFileName(for: item)"))
        XCTAssertTrue(code.contains("Self.exportURL(for: item, in: tempDir)"))
        XCTAssertTrue(code.contains("if tempDir.lastPathComponent.hasPrefix(\"vault-save-\")"))
    }
}
