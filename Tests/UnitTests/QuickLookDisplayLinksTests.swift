import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// The document viewer hands QuickLook a hard link to the cached decrypted
/// file, so the preview shows the real filename. A hard link is a second
/// name for the same bytes: until these tests' fix, deleting the cached
/// file left the plaintext readable under tmp/sanchr-quicklook.
final class QuickLookDisplayLinksTests: XCTestCase {

    private final class FakeDownload: MediaDownloading {
        let url: URL
        init(url: URL) { self.url = url }
        func download(messageId: String, attachment: Message.MediaAttachment) async throws -> URL { url }
    }

    private var root: URL!
    private var cached: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("links", isDirectory: true)
        cached = base.appendingPathComponent("msg-1.pdf")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("plaintext".utf8).write(to: cached)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func linkCount(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.referenceCount] as? Int)
    }

    private func attachment() -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://m1")!,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: "application/pdf",
            sizeBytes: 9,
            filename: "Invoice Q4.pdf"
        )
    }

    private func makeLink() async throws -> URL {
        let resolver = ChatMediaResolverImpl(download: FakeDownload(url: cached), displayLinkRoot: root)
        return try await resolver.decryptedURLWithDisplayName(forMessageId: "msg-1", attachment: attachment())
    }

    func testTheLinkIsAHardLinkToTheCachedBytes() async throws {
        let linked = try await makeLink()
        XCTAssertEqual(linked.lastPathComponent, "Invoice Q4.pdf")
        XCTAssertEqual(try linkCount(cached), 2)
    }

    /// The bug: with only the cached file removed, the bytes stayed on disk.
    func testRemovingTheMessageDropsTheLinkAndTheBytesWithIt() async throws {
        let linked = try await makeLink()

        QuickLookDisplayLinks.remove(messageId: "msg-1", root: root)
        try FileManager.default.removeItem(at: cached)

        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.deletingLastPathComponent().path))
    }

    func testRemovingAnUnknownMessageIsANoOp() async throws {
        let linked = try await makeLink()
        QuickLookDisplayLinks.remove(messageId: "someone-else", root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
    }

    func testSweepRemovesEveryLink() async throws {
        let linked = try await makeLink()
        QuickLookDisplayLinks.sweep(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertEqual(try linkCount(cached), 1)
    }

    /// The resolver is built once per launch; whatever a previous run left
    /// is plaintext for media that may have been deleted since.
    func testANewResolverSweepsLeftovers() async throws {
        let linked = try await makeLink()
        _ = ChatMediaResolverImpl(download: FakeDownload(url: cached), displayLinkRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the root is recreated for the new session")
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testEveryCacheRemovalPathAlsoRemovesTheLinks() throws {
        let manager = try source("Shared/Services/MediaDownloadManager.swift")
        let removal = try XCTUnwrap(manager.range(of: "func removeCachedFile(messageId: String) {"))
        let body = String(manager[removal.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("QuickLookDisplayLinks.remove(messageId: messageId)"))
    }

    func testSigningOutSweepsTheLinks() throws {
        let container = try source("App/DependencyContainer.swift")
        for fn in ["func wipeLocalSessionArtifacts", "func wipeAppGroupArtifacts"] {
            let start = try XCTUnwrap(container.range(of: fn))
            let body = String(container[start.upperBound...].prefix(2500))
            XCTAssertTrue(body.contains("QuickLookDisplayLinks.sweep()"), "\(fn) must sweep the QuickLook links")
        }
    }
}
