import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// A forward into the conversation you are looking at.
final class ForwardEchoTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The row is written against the target conversation, which is correct
    /// and invisible: the transcript on screen is already loaded and does not
    /// re-read the database. Forwarding to the chat you were in showed nothing
    /// until it was reopened.
    func testAForwardIntoTheOpenChatIsShownImmediately() throws {
        let body = code(try source("Features/Chats/Presentation/ChatDetailViewModel+Send.swift"))
        XCTAssertTrue(body.contains("func echoIntoCurrentConversation("))
        XCTAssertTrue(
            body.contains("guard targets.contains(currentConversationId) else { return nil }"),
            "only the conversation on screen needs an echo; the others reload"
        )
        XCTAssertTrue(body.contains("appendMessageChronologically(echo)"))
    }

    /// The echo has to end up looking like what happened.
    func testTheEchoIsSettledOnceEveryDestinationHasAnswered() throws {
        let body = code(try source("Features/Chats/Presentation/ChatDetailViewModel+Send.swift"))
        XCTAssertTrue(body.contains("settle(echo, allFailed: failures == targetConversationIds.count)"))
        XCTAssertTrue(body.contains("$0.status = allFailed ? .failed : .sent"))
    }

    /// Media has to render from the file on disk, not the remote reference the
    /// original carried — the echo is drawn before anything is uploaded.
    func testAMediaEchoPointsAtTheLocalFile() {
        let local = Message.MediaAttachment(
            url: URL(fileURLWithPath: "/tmp/local.jpg"),
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: "image/jpeg", sizeBytes: 10
        )
        let remote = Message.MediaAttachment(
            url: URL(string: "sanchr-media://abc")!,
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: "image/jpeg", sizeBytes: 10
        )
        let swapped = Message.MessageContent
            .image(Message.MediaAttachments(remote))
            .replacingSoleAttachment(local)

        guard case .image(let attachments) = swapped else {
            return XCTFail("the case must be preserved")
        }
        XCTAssertEqual(attachments.items.first?.url, local.url)
    }

    /// Swapping an attachment into content that has none must not invent one.
    func testTextContentIsUnchangedByAnAttachmentSwap() {
        let attachment = Message.MediaAttachment(
            url: URL(fileURLWithPath: "/tmp/x.jpg"),
            encryptionKey: Data(), encryptionIV: Data(),
            mimeType: "image/jpeg", sizeBytes: 10
        )
        let text = Message.MessageContent.text("hello")
        guard case .text(let value) = text.replacingSoleAttachment(attachment) else {
            return XCTFail("text must stay text")
        }
        XCTAssertEqual(value, "hello")
    }

    /// `VideoPlayer` letterboxes inside whatever frame it is handed and does
    /// not expose gravity, so the previous attempt at filling changed nothing.
    func testTheVideoPreviewControlsGravityDirectly() throws {
        let caption = code(try source("Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift"))
        XCTAssertFalse(
            caption.contains("VideoPlayer(player: player)"),
            "VideoPlayer cannot fill; that is the bug"
        )
        XCTAssertTrue(caption.contains("VideoPreviewLayer("))

        let layer = code(try source("Features/Chats/Presentation/MediaCaption/VideoPreviewLayer.swift"))
        XCTAssertTrue(layer.contains("videoGravity = fills ? .resizeAspectFill : .resizeAspect"))
    }
}
