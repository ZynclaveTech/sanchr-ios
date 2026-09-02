import SanchrShared
import SwiftUI
import UIKit
import XCTest

@testable import Sanchr

/// A SwiftUI button declared over the transcript draws above it but
/// hit-tests below it — the touch went to the bubble behind. Hosting the
/// button in its own UIKit layer fixes that; this test puts the real
/// transcript and a hoisted button in a window and asks UIKit who gets the
/// touch.
@MainActor
final class ScrollFabHitTests: XCTestCase {

    private struct Host: View {
        let hoisted: Bool
        @State private var atBottom = false
        @State private var count = 0

        private var transcript: some View {
            MessageCollectionView(
                renderInput: TranscriptRenderInput(
                    sections: [MessageSection(id: Date(), title: "Today", messages: (0..<40).map { i in
                        Message.textMessage(conversationId: "c", senderId: i % 2 == 0 ? "me" : "peer",
                                            text: "Message \(i), long enough to wrap onto a second line in the window",
                                            isOutgoing: i % 2 == 0)
                    })],
                    uploads: UploadProgressStore(), uploadsVersion: 0, version: 1,
                    scrollCommand: .initialBottom(sequence: 0), firstUnreadMessageId: nil
                ),
                peerDisplayName: "Peer", localUserId: "me", voicePlayback: VoicePlaybackController(),
                onInitialPresentation: {}, onReply: { _ in }, onReact: { _, _ in }, onDeleteMessage: { _ in },
                onForward: { _ in }, onMediaAction: { _, _ in }, onLongPressMessage: { _ in },
                onRetry: { _ in }, onLoadMore: {}, onBubbleTap: { _ in },
                isScrolledToBottom: $atBottom, newMessageCountWhileScrolled: $count
            )
        }

        private var button: some View {
            Button {} label: {
                Image(systemName: "chevron.down").frame(width: 40, height: 40)
                    .background(Color.white).clipShape(Circle())
            }
            .buttonStyle(.plain)
        }

        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                transcript
                Group {
                    if hoisted { HostedAboveUIKit { button } } else { button }
                }
                .padding(.trailing, 16).padding(.bottom, 12)
            }
        }
    }

    private func viewHit(hoisted: Bool) -> [String] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: Host(hoisted: hoisted))
        window.makeKeyAndVisible()
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        window.layoutIfNeeded()
        var chain: [String] = []
        var view = window.hitTest(CGPoint(x: 390 - 16 - 20, y: 844 - 12 - 20), with: nil)
        while let current = view, chain.count < 8 {
            chain.append(String(describing: type(of: current)))
            view = current.superview
        }
        return chain
    }

    /// Documents the failure the fix is for. If SwiftUI ever changes this,
    /// the wrapper may be able to go.
    func testAPlainButtonOverTheTranscriptIsHitTestedBelowIt() {
        let chain = viewHit(hoisted: false)
        XCTAssertTrue(chain.contains { $0 == "UICollectionViewCell" }, "\(chain)")
    }

    func testTheHoistedButtonReceivesTheTouch() {
        let chain = viewHit(hoisted: true)
        XCTAssertFalse(chain.contains { $0 == "UICollectionViewCell" || $0 == "ObservedCollectionView" }, "\(chain)")
        XCTAssertTrue(chain.contains { $0.hasPrefix("_UIHostingView<") }, "\(chain)")
    }

    func testTheChatScreenHoistsItsButton() throws {
        let view = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Chats/Presentation/ChatDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(view.contains("HostedAboveUIKit { scrollToBottomFAB }"))
    }
}
