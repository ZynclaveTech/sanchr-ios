import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// Tapping a vault item used to do nothing: it could be exported, not seen.
@MainActor
final class VaultOpenItemTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-open-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String = "i1", named name: String = "report.pdf") -> VaultItem {
        VaultItem(
            id: id, mediaId: "m", name: name, type: .document, sizeBytes: 3,
            createdAt: Date(), updatedAt: Date()
        )
    }

    private func filesUnderRoot() -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { !$0.hasPrefix("open-") || $0.contains("/") }
    }

    func testOpeningAnItemPutsItsContentWhereTheViewerCanReadIt() async throws {
        let viewModel = VaultViewModel()

        await viewModel.open(item(), download: { _ in Data([1, 2, 3]) }, root: root)

        let opened = try XCTUnwrap(viewModel.openedItem)
        XCTAssertEqual(opened.item.id, "i1")
        XCTAssertEqual(opened.url.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: opened.url), Data([1, 2, 3]))
        XCTAssertTrue(opened.url.path.hasPrefix(root.path + "/"))
        XCTAssertNil(viewModel.openingItemId)
    }

    /// The decrypted copy exists for the viewer and must not outlive it.
    func testClosingTheViewerRemovesThePlaintext() async throws {
        let viewModel = VaultViewModel()
        await viewModel.open(item(), download: { _ in Data([1, 2, 3]) }, root: root)
        let url = try XCTUnwrap(viewModel.openedItem?.url)

        viewModel.closeOpenedItem()

        XCTAssertNil(viewModel.openedItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testADownloadThatFailsOpensNothingAndLeavesNothingBehind() async {
        struct Offline: Error {}
        let viewModel = VaultViewModel()

        await viewModel.open(item(), download: { _ in throw Offline() }, root: root)

        XCTAssertNil(viewModel.openedItem)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.openingItemId)
        XCTAssertTrue(filesUnderRoot().isEmpty)
    }

    /// The name is the sender's. It must not write outside its own directory.
    func testANameThatClimbsOutOfTheDirectoryCannotPutAFileElsewhere() async throws {
        let viewModel = VaultViewModel()

        await viewModel.open(item(named: "../../escaped.txt"), download: { _ in Data([9]) }, root: root)

        if let opened = viewModel.openedItem {
            XCTAssertTrue(opened.url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/open-"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    func testASecondTapWhileOneItemIsOpenDoesNotOpenAnother() async throws {
        let viewModel = VaultViewModel()
        await viewModel.open(item("first"), download: { _ in Data([1]) }, root: root)

        await viewModel.open(item("second"), download: { _ in Data([2]) }, root: root)

        XCTAssertEqual(viewModel.openedItem?.item.id, "first")
    }

    /// In select mode a tap picks the item; it must not also open it.
    func testNothingOpensWhileSelecting() async {
        let viewModel = VaultViewModel()
        viewModel.enterSelectMode()

        await viewModel.open(item(), download: { _ in Data([1]) }, root: root)

        XCTAssertNil(viewModel.openedItem)
    }

    /// Kept where the launch sweep clears, so a preview the app died under goes too.
    func testOpenedItemsLiveUnderTheDirectorySweptAtLaunch() {
        XCTAssertTrue(
            VaultViewModel.openedItemsRoot.path.hasPrefix(QuickLookDisplayLinks.root.path + "/"))
    }
}
