// PhotosLibrarySourceTests.swift
import XCTest
import Photos
import SanchrShared
@testable import Sanchr

final class PhotosLibrarySourceTests: XCTestCase {

    func test_fetchOptions_limit60_sortedDesc() {
        let opts = PhotosLibrarySource.makeFetchOptions()
        XCTAssertEqual(opts.fetchLimit, 60)
        XCTAssertEqual(opts.sortDescriptors?.count, 1)
        let sort = opts.sortDescriptors!.first!
        XCTAssertEqual(sort.key, "creationDate")
        XCTAssertFalse(sort.ascending)
    }

    func test_recentPhoto_mapsAssetMetadataCorrectly() {
        let fake = FakeAssetLike(
            localIdentifier: "abc",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            pixelWidth: 4032,
            pixelHeight: 3024,
            mediaTypeIsVideo: false,
            duration: 0
        )
        let rp = PhotosLibrarySource.recentPhoto(from: fake)
        XCTAssertEqual(rp.id, "abc")
        XCTAssertEqual(rp.kind, .photo)
        XCTAssertEqual(rp.width, 4032)
        XCTAssertNil(rp.durationSeconds)
    }

    func test_recentPhoto_video_carriesDuration() {
        let fake = FakeAssetLike(
            localIdentifier: "vid",
            creationDate: nil,
            pixelWidth: 1920,
            pixelHeight: 1080,
            mediaTypeIsVideo: true,
            duration: 42.5
        )
        let rp = PhotosLibrarySource.recentPhoto(from: fake)
        XCTAssertEqual(rp.kind, .video)
        XCTAssertEqual(rp.durationSeconds, 42.5)
    }
}

private struct FakeAssetLike: PhotosAssetLike {
    let localIdentifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaTypeIsVideo: Bool
    let duration: TimeInterval
}
