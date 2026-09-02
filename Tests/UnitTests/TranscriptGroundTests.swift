import SwiftUI
import XCTest
@testable import Sanchr

/// Timestamps, receipts and the date chip sit on the chat background. On a
/// dark wallpaper in light theme they resolved to translucent black and
/// vanished; the mirror case hid them on light wallpapers in dark theme.
final class TranscriptGroundTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testGroundFollowsTheWallpapersLuminanceNotTheScheme() {
        XCTAssertEqual(TranscriptGround.forWallpaper(id: "default"), .system)
        XCTAssertEqual(TranscriptGround.forWallpaper(id: ""), .system, "legacy/empty id keeps the system surface")
        XCTAssertEqual(TranscriptGround.forWallpaper(id: "not-a-wallpaper"), .system)
        XCTAssertEqual(TranscriptGround.forWallpaper(id: "dark_indigo"), .darkWallpaper)
        XCTAssertEqual(TranscriptGround.forWallpaper(id: "midnight"), .darkWallpaper)
        XCTAssertEqual(TranscriptGround.forWallpaper(id: "indigo_mist"), .lightWallpaper)
    }

    func testOnWallpaperColoursContrastWithTheGround() {
        // Light ink on dark, dark ink on light; never a scheme-dependent colour.
        XCTAssertEqual(UIColor(TranscriptGround.darkWallpaper.timestampColor).luminance, 1, accuracy: 0.01)
        XCTAssertEqual(UIColor(TranscriptGround.lightWallpaper.timestampColor).luminance, 0, accuracy: 0.01)
        XCTAssertEqual(UIColor(TranscriptGround.darkWallpaper.chipText).luminance, 1, accuracy: 0.01)
        XCTAssertEqual(UIColor(TranscriptGround.lightWallpaper.chipText).luminance, 0, accuracy: 0.01)
    }

    func testTheGroundReachesEveryOnBackgroundElement() throws {
        let bubble = try source("Features/Chats/Presentation/MessageBubble.swift")
        let row = try XCTUnwrap(bubble.range(of: "private var timestampRow: some View {"))
        let rowBody = String(bubble[row.upperBound...].prefix(1200))
        XCTAssertFalse(rowBody.contains("SanchrExportColors.textTertiary"), "timestamp row must use the ground colour")
        XCTAssertEqual(rowBody.components(separatedBy: "ground.timestampColor").count - 1, 3, "time, single tick and unread double tick")

        let controller = try source("Features/Chats/Presentation/MessageCollectionViewController.swift")
        for needle in ["ground.chipText", "ground.chipBackground", "ground.chipStroke",
                       ".environment(\\.transcriptGround, self?.ground ?? .system)", "collectionView.reloadData()"] {
            XCTAssertTrue(controller.contains(needle), "controller lost `\(needle)`")
        }
        XCTAssertTrue(try source("Features/Chats/Presentation/ChatTranscriptView.swift").contains("ground: TranscriptGround.forWallpaper("))
        XCTAssertTrue(try source("Features/Chats/Presentation/MessageCollectionView.swift").contains("vc.ground = ground"))
    }
}

private extension UIColor {
    /// Relative brightness of the colour ignoring alpha: 1 for white, 0 for black.
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
