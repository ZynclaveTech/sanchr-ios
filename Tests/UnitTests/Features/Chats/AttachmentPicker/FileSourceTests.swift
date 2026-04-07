// FileSourceTests.swift
import XCTest
import SanchrShared
@testable import Sanchr

final class FileSourceTests: XCTestCase {

    func test_copyIntoSandbox_producesFileInStagingDir() throws {
        let src = try makeTempFile(contents: Data([0x01, 0x02, 0x03]))
        let dest = try FileSource.copyIntoSandbox(url: src, filename: "test.bin")
        XCTAssertTrue(dest.path.contains("attachment-staging"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        try FileManager.default.removeItem(at: dest)
    }

    func test_enforceSizeCap_rejectsOver100MB() {
        XCTAssertFalse(FileSource.isSizeAcceptable(bytes: 100 * 1024 * 1024 + 1))
        XCTAssertTrue(FileSource.isSizeAcceptable(bytes: 100 * 1024 * 1024))
    }

    func test_mimeType_fromExtension() {
        XCTAssertEqual(FileSource.mimeType(forFilename: "doc.pdf"), "application/pdf")
        XCTAssertEqual(FileSource.mimeType(forFilename: "a.txt"), "text/plain")
        XCTAssertEqual(FileSource.mimeType(forFilename: "u.zzzzz"), "application/octet-stream")
    }

    private func makeTempFile(contents: Data) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: u)
        return u
    }
}
