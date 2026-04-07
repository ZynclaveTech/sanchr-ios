import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class VaultSourceAdapterTests: XCTestCase {
    func test_loadAll_delegatesToGetVaultItemsWithAllFilter() async throws {
        let spy = SpyGetVaultItems()
        let source = VaultSource(getVaultItems: spy)
        _ = try await source.loadAll()
        XCTAssertEqual(spy.receivedFilter, "all")
        XCTAssertEqual(spy.receivedLimit, 100)
        XCTAssertEqual(spy.receivedCursor, "")
    }

    func test_load_withFilter_passesThrough() async throws {
        let spy = SpyGetVaultItems()
        let source = VaultSource(getVaultItems: spy)
        _ = try await source.load(filter: "photo")
        XCTAssertEqual(spy.receivedFilter, "photo")
        XCTAssertEqual(spy.receivedLimit, 100)
    }
}

private final class SpyGetVaultItems: VaultItemsLoading, @unchecked Sendable {
    var receivedFilter: String?
    var receivedLimit: Int32?
    var receivedCursor: String?
    func execute(
        filter: String,
        limit: Int32,
        cursor: String
    ) async throws -> (items: [VaultItem], totalPhotos: Int32, totalVideos: Int32, totalFiles: Int32) {
        receivedFilter = filter
        receivedLimit = limit
        receivedCursor = cursor
        return (items: [], totalPhotos: 0, totalVideos: 0, totalFiles: 0)
    }
}
