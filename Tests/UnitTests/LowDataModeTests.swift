import CoreGraphics
import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// Low Data Mode existed as a synced setting that nothing read. It now caps
/// auto-download at photos and voice notes on every connection, and sends
/// video at 540p.
final class LowDataModeTests: XCTestCase {

    func testLowDataCapsWifiDownloadsAtPhotos() {
        XCTAssertEqual(
            AutoDownloadPolicy.decision(mimeType: "video/mp4", connection: .wifi, wifi: "all", mobile: "all", lowData: true),
            .manual
        )
        XCTAssertEqual(
            AutoDownloadPolicy.decision(mimeType: "image/jpeg", connection: .wifi, wifi: "all", mobile: "all", lowData: true),
            .automatic
        )
        XCTAssertEqual(
            AutoDownloadPolicy.decision(mimeType: "video/mp4", connection: .wifi, wifi: "all", mobile: "all", lowData: false),
            .automatic
        )
    }

    func testLowDataDoesNotLoosenAStricterSetting() {
        XCTAssertEqual(
            AutoDownloadPolicy.decision(mimeType: "image/jpeg", connection: .cellular, wifi: "all", mobile: "none", lowData: true),
            .manual
        )
    }

    func testLowDataCompressesAClipThatWouldOtherwiseGoUntouched() {
        // 720p and 3 MB: within the normal target, over the low-data one.
        let size = CGSize(width: 1280, height: 720)
        let bytes: Int64 = 3 * 1024 * 1024
        XCTAssertEqual(VideoCompressionPolicy.decide(pixelSize: size, byteCount: bytes), .sendOriginal(reason: "already within target"))
        XCTAssertEqual(VideoCompressionPolicy.decide(pixelSize: size, byteCount: bytes, lowData: true), .compress)
    }

    func testTheSwitchIsMirroredAndRead() throws {
        let sender = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("SanchrShared/Messaging/MessageSender.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sender.contains("lowData: AutoDownloadSettingsStore.lowDataMode"))
    }
}
