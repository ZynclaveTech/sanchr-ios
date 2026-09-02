import Foundation
import XCTest

@testable import Sanchr

/// A retried upload must not encrypt the file a second time.
///
/// Encryption reads the whole file, and each run ratchets the
/// conversation's media chain — for an upload whose ciphertext already
/// exists on disk from the previous attempt.
final class UploadRetryTests: XCTestCase {

    func testARetryReusesTheCiphertext() throws {
        let manager = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("SanchrShared/Media/MediaUploadManager.swift"),
            encoding: .utf8
        )
        let execute = try XCTUnwrap(manager.range(of: "func execute(_ taskId: String) async -> MediaUploadTask? {"))
        let body = String(manager[execute.upperBound...].prefix(6000))
        XCTAssertTrue(body.contains("let encryptedURL = task.encryptedFileURL ?? tempDir.appendingPathComponent"))
        let guardRange = try XCTUnwrap(body.range(of: "if hasCiphertext {"))
        let encrypt = try XCTUnwrap(body.range(of: "mediaEncryption.encryptFile("))
        XCTAssertLessThan(guardRange.lowerBound, encrypt.lowerBound, "the reuse check must come before encryption")
    }
}
