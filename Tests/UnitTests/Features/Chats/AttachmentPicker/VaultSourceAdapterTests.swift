import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class VaultSourceAdapterTests: XCTestCase {
    func test_loadAll_delegatesToGetVaultItemsWithNoFilter() async throws {
        let spy = SpyGetVaultItems()
        let source = VaultSource(getVaultItems: spy)
        _ = try await source.loadAll()
        XCTAssertEqual(spy.receivedLimit, 100)
        XCTAssertEqual(spy.receivedCursor, "")
    }

    func test_load_withFilter_appliesClientSideFilter() async throws {
        let spy = SpyGetVaultItems()
        let source = VaultSource(getVaultItems: spy)
        // Seed two items of different types so the client-side filter is
        // observable. The picker's load(filter:) scans and returns only
        // matching types because the server-side filter is gone (metadata
        // is encrypted client-side in the forward-secure design).
        let photo = VaultItem(
            id: "photo-1",
            mediaId: "m1",
            name: "photo",
            type: .photo,
            sizeBytes: 10,
            createdAt: Date(),
            updatedAt: Date()
        )
        let video = VaultItem(
            id: "video-1",
            mediaId: "m2",
            name: "video",
            type: .video,
            sizeBytes: 20,
            createdAt: Date(),
            updatedAt: Date()
        )
        spy.nextResult = VaultUseCases.GetVaultItems.Result(
            items: [photo, video],
            nextCursor: ""
        )

        let result = try await source.load(filter: "photo")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .photo)
        XCTAssertEqual(spy.receivedLimit, 100)
    }
}

private final class SpyGetVaultItems: VaultItemsLoading, @unchecked Sendable {
    var receivedLimit: Int32?
    var receivedCursor: String?
    var nextResult: VaultUseCases.GetVaultItems.Result = .init(items: [], nextCursor: "")

    func execute(
        limit: Int32,
        cursor: String
    ) async throws -> VaultUseCases.GetVaultItems.Result {
        receivedLimit = limit
        receivedCursor = cursor
        return nextResult
    }
}
