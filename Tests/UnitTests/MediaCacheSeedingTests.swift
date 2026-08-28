import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Seeding the sender's own media into the cache.
///
/// Sending used to seed only after the server replied. For the whole upload —
/// not brief for a large video — the optimistic row had no cache entry, so its
/// bubbles depended on the picker temp file still existing. When it did not,
/// every fallback missed and the bubble asked to download a `file://` URL,
/// which has no server behind it.
final class MediaCacheSeedingTests: XCTestCase {

    private var manager: MediaDownloadManager!
    private var source: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        manager = MediaDownloadManager(
            mediaEncryption: StubMediaEncryption(),
            accessKeyStore: StubAccessKeyStore(),
            grpcClient: StubGRPCClient(messagingService: SpyMessagingService()),
            vaultEKFScheduler: VaultEKFScheduler(accessKeyStore: StubAccessKeyStore())
        )
        source = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString).jpg")
        try Data("pretend jpeg".utf8).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        try super.tearDownWithError()
    }

    private func id() -> String { "msg-\(UUID().uuidString)" }

    func testASeededFileIsFoundByTheSameLookupTheBubbleUses() async throws {
        let messageId = id()
        await manager.cacheLocalCopy(of: source, messageId: messageId, mimeType: "image/jpeg")

        let found = await manager.cachedURL(
            for: messageId,
            ext: MediaCacheFile.fileExtension(for: "image/jpeg")
        )
        let url = try XCTUnwrap(found, "seeded file was not findable")
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: source))
        await manager.removeCachedFile(messageId: messageId)
    }

    /// The regression. A GIF was written as `.bin` and looked up as `.jpg`, so
    /// it was cached and then re-downloaded forever.
    func testAGifIsFoundAfterSeeding() async throws {
        let messageId = id()
        await manager.cacheLocalCopy(of: source, messageId: messageId, mimeType: "image/gif")

        let found = await manager.cachedURL(
            for: messageId,
            ext: MediaCacheFile.fileExtension(for: "image/gif")
        )
        XCTAssertNotNil(found, "a GIF must be findable under the name it was written with")
        await manager.removeCachedFile(messageId: messageId)
    }

    /// Re-keying must move, not copy. Leaving the optimistic entry behind
    /// would double the disk cost of every send and orphan a file nothing
    /// ever looks up again.
    func testRecacheMovesTheEntryRatherThanCopyingIt() async throws {
        let optimistic = id()
        let server = id()
        await manager.cacheLocalCopy(of: source, messageId: optimistic, mimeType: "image/jpeg")
        await manager.recache(from: optimistic, to: server, mimeType: "image/jpeg")

        let ext = MediaCacheFile.fileExtension(for: "image/jpeg")
        let old = await manager.cachedURL(for: optimistic, ext: ext)
        let new = await manager.cachedURL(for: server, ext: ext)
        XCTAssertNil(old, "the optimistic entry was left behind")
        XCTAssertNotNil(new, "the entry did not arrive under the server id")
        await manager.removeCachedFile(messageId: server)
    }

    /// The send can fail before the id exists. Nothing should be left over.
    func testRecacheFromAMissingEntryIsANoOp() async {
        let server = id()
        await manager.recache(from: id(), to: server, mimeType: "image/jpeg")
        let found = await manager.cachedURL(
            for: server,
            ext: MediaCacheFile.fileExtension(for: "image/jpeg")
        )
        XCTAssertNil(found, "re-keying nothing must not create an empty entry")
    }

    /// A retry can seed over a previous attempt. `copyItem` refuses to
    /// overwrite, so without removing first the second seed would silently
    /// leave the first attempt's bytes in place.
    func testSeedingTwiceKeepsTheNewerBytes() async throws {
        let messageId = id()
        await manager.cacheLocalCopy(of: source, messageId: messageId, mimeType: "image/jpeg")

        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString).jpg")
        try Data("second attempt".utf8).write(to: replacement)
        defer { try? FileManager.default.removeItem(at: replacement) }
        await manager.cacheLocalCopy(of: replacement, messageId: messageId, mimeType: "image/jpeg")

        let cached = await manager.cachedURL(
            for: messageId,
            ext: MediaCacheFile.fileExtension(for: "image/jpeg")
        )
        let found = try XCTUnwrap(cached)
        XCTAssertEqual(String(data: try Data(contentsOf: found), encoding: .utf8), "second attempt")
        await manager.removeCachedFile(messageId: messageId)
    }

    /// A remote URL is not ours to copy; seeding must ignore it rather than
    /// creating an empty file that later reads as a cache hit.
    func testARemoteURLIsNotSeeded() async {
        let messageId = id()
        await manager.cacheLocalCopy(
            of: URL(string: "sanchr-media://abc123")!,
            messageId: messageId,
            mimeType: "image/jpeg"
        )
        let found = await manager.cachedURL(
            for: messageId,
            ext: MediaCacheFile.fileExtension(for: "image/jpeg")
        )
        XCTAssertNil(found, "a remote URL must not produce a cache entry")
    }

    /// Album tiles share a message id and must not collapse onto one entry.
    func testAlbumTilesSeedIndependently() async throws {
        let messageId = id()
        for index in 0..<3 {
            await manager.cacheLocalCopy(
                of: source,
                messageId: "\(messageId)#\(index)",
                mimeType: "image/jpeg"
            )
        }
        let ext = MediaCacheFile.fileExtension(for: "image/jpeg")
        for index in 0..<3 {
            let found = await manager.cachedURL(for: "\(messageId)#\(index)", ext: ext)
            XCTAssertNotNil(found, "tile \(index) is missing")
        }
        for index in 0..<3 {
            await manager.removeCachedFile(messageId: "\(messageId)#\(index)")
        }
    }
}
