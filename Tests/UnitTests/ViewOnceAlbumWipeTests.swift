import XCTest

@testable import Sanchr

/// Consuming a view-once album must wipe every tile, not just the first.
///
/// An album tile is cached as `<messageId>#<n>.<ext>` and linked under a
/// directory of the same name, while the lead photo uses the bare message id.
/// Both removal paths matched only `"<messageId>."`, so the decrypted
/// plaintext of every tile after the first survived on disk — and the gallery
/// made it worse by asking for a delete under the page id, which matches no
/// database row at all, so the delete returned early having removed nothing.
final class ViewOnceAlbumWipeTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func test_cacheRemovalMatchesAlbumTileNames() throws {
        let manager = try source("Shared/Services/MediaDownloadManager.swift")
        let start = try XCTUnwrap(manager.range(of: "func removeCachedFile(messageId: String) {"))
        let body = String(manager[start.upperBound...].prefix(900))

        // Matched on the name the files were written under, which is the id
        // made safe for a path, not the id as it arrived.
        XCTAssertTrue(body.contains("let name = MediaCacheFile.safeId(messageId)"))
        XCTAssertTrue(
            body.contains("hasPrefix(name + \"#\")"),
            "cache removal must also match an album's \"<messageId>#<n>\" tiles")
    }

    func test_quickLookLinkRemovalMatchesAlbumTileDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicklook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for name in ["m1", "m1#0", "m1#1", "m10", "m2#0"] {
            try fm.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }

        QuickLookDisplayLinks.remove(messageId: "m1", root: root)

        // The message's own directory and every tile's; nothing of a
        // neighbour whose id merely starts the same way.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), ["m10", "m2#0"])
    }

    func test_galleryConsumesByMessageIdNotPageId() throws {
        let gallery = try source("Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift")

        // `item.id` is "<messageId>#<n>" for an album tile, and
        // `deleteViewOnceMessage` looks up a row by exactly what it is given.
        XCTAssertTrue(gallery.contains("openedViewOnceItems.insert(item.messageId)"))
        XCTAssertFalse(gallery.contains("openedViewOnceItems.insert(item.id)"))
    }
}
