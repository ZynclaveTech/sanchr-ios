import Foundation
import XCTest

@testable import Sanchr

/// "Media expired" everywhere a gone file used to show a retry that could
/// only fail again: the video tile over its blurhash, the full-screen
/// viewer, the document alert, and voice notes.
final class MediaExpiredSurfacesTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// A blurhash used to hide the failure: the tile stayed a blur with a
    /// play glyph on it.
    func testTheTileShowsExpiredOverABlurhashAndDropsThePlayGlyph() throws {
        let bubble = try source("Features/Chats/Presentation/MediaBubbleImage.swift")
        let overlay = try XCTUnwrap(bubble.range(of: "if let progress = uploadProgress, resolvedImage != nil {"))
        let body = String(bubble[overlay.upperBound...].prefix(500))
        XCTAssertTrue(body.contains("} else if loadFailure == .expired {"))
        XCTAssertTrue(body.contains("} else if showsPlayGlyph {"))
        let message = try source("Features/Chats/Presentation/MessageBubble.swift")
        XCTAssertTrue(message.contains("showsPlayGlyph: true,"))
        XCTAssertFalse(message.contains("Image(systemName: \"play.circle.fill\")"), "the glyph is the tile's to draw")
    }

    func testTheViewerSaysExpiredWithoutARetry() throws {
        let loader = try source("Features/Chats/Presentation/Viewers/MediaGallery/GalleryPageLoader.swift")
        XCTAssertTrue(loader.contains("isExpired: (error as? AppError) == .mediaExpired"))
        let page = try source("Features/Chats/Presentation/Viewers/MediaGallery/GalleryPageView.swift")
        XCTAssertTrue(page.contains("retryView(error: error, isExpired: state.isExpired)"))
        XCTAssertTrue(page.contains("Text(\"Media expired\")"))
        XCTAssertTrue(page.contains("if isExpired {\n                EmptyView()\n            } else if #available(iOS 26.0, *) {"),
                      "no Retry button on an expired page")
    }

    func testTheDocumentAlertNamesExpiry() throws {
        let coordinator = try source("Features/Chats/Presentation/Viewers/Document/DocumentPreviewCoordinator.swift")
        XCTAssertTrue(coordinator.contains("resolveErrorIsExpiry = (error as? AppError) == .mediaExpired"))
        let chat = try source("Features/Chats/Presentation/ChatDetailView.swift")
        XCTAssertTrue(chat.contains("documentCoordinator.resolveErrorIsExpiry ? \"File expired\" : \"Couldn't open file\""))
        XCTAssertTrue(chat.contains(".alert(documentAlertTitle, isPresented:"))
    }

    /// A received note arrives as a sanchr-media:// URL; the bubble handed
    /// it straight to AVAudioPlayer and the tap did nothing.
    func testVoiceNotesAreFetchedBeforePlayingAndSayWhenTheyAreGone() throws {
        let bubble = try source("Features/Chats/Presentation/VoiceMessage/VoicePlaybackBubble.swift")
        XCTAssertTrue(bubble.contains("container.mediaDownloadManager.download("))
        XCTAssertTrue(bubble.contains("catch let error as AppError where error == .mediaExpired {\n                loadState = .expired"))
        XCTAssertTrue(bubble.contains("case .expired: return \"Expired\""))
        XCTAssertTrue(bubble.contains(".disabled(loadState == .expired || loadState == .loading)"))
        XCTAssertFalse(bubble.contains("let url: URL"), "the bubble takes the attachment, not a URL it cannot play")
    }
}
