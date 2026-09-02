import SwiftUI
import XCTest
@testable import Sanchr

/// Guards the chat-entry latency work: the first push into a chat used to pay
/// ~700 ms (simulator, cold) of one-time SwiftUI/UIKit costs. A hidden
/// `ChatSurfacePrewarmView` behind the splash pays them at launch instead, and
/// the chat's entry task starts the message load before the appearance/vault
/// reads so the DB work overlaps.
@MainActor
final class ChatSurfacePrewarmTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testPrewarmIsHostedBehindTheSplash() throws {
        let app = try source("App/SanchrApp.swift")
        let splashBlock = try XCTUnwrap(app.range(of: "if showSplash {"))
        let prewarm = try XCTUnwrap(app.range(of: "ChatSurfacePrewarmView()"))
        let splashView = try XCTUnwrap(app.range(of: "SplashView(markNamespace: brandMark)"))
        XCTAssertLessThan(splashBlock.lowerBound, prewarm.lowerBound)
        XCTAssertLessThan(prewarm.lowerBound, splashView.lowerBound, "prewarm sits under the splash in the ZStack")
    }

    func testPrewarmCoversEveryFirstUseCost() throws {
        let view = try source("Features/Chats/Presentation/ChatSurfacePrewarmView.swift")
        for needle in ["MessageCollectionView(", "role: .floatingAction", "role: .toolbarButton", "role: .chip",
                       "axis: .vertical", ".opacity(0)", ".allowsHitTesting(false)", ".accessibilityHidden(true)"] {
            XCTAssertTrue(view.contains(needle), "prewarm view lost `\(needle)`")
        }
    }

    func testPrewarmMountsWithoutCrashingAndStaysInvisible() throws {
        let container = DependencyContainer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: ChatSurfacePrewarmView()
            .environment(container).environment(AppRouter()).environment(container.syncState))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // Pump the main run loop until the transcript's collection view (the
        // one real UIKit subview) is mounted.
        func containsCollectionView(_ view: UIView) -> Bool {
            view is UICollectionView || view.subviews.contains(where: containsCollectionView)
        }
        let deadline = Date().addingTimeInterval(3)
        while !containsCollectionView(host.view), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
        }
        XCTAssertTrue(containsCollectionView(host.view), "prewarm content did not mount; tree: \(host.view.perform(Selector(("recursiveDescription")))?.takeUnretainedValue() ?? "" as AnyObject)")
        // allowsHitTesting(false): touches fall through the prewarm to whatever is under it.
        let hit = host.view.hitTest(CGPoint(x: 195, y: 400), with: nil)
        XCTAssertTrue(hit == nil || hit === host.view, "prewarm content must not capture touches, got \(String(describing: hit))")
    }

    func testEntryTaskStartsMessageLoadBeforeAppearanceReads() throws {
        let view = try source("Features/Chats/Presentation/ChatDetailView.swift")
        let asyncLet = try XCTUnwrap(view.range(of: "async let messagesLoaded: Void = viewModel.loadMessages("))
        let override = try XCTUnwrap(view.range(of: "await container.chatAppearance.loadOverride(conversationId: conversation.id)"))
        let awaited = try XCTUnwrap(view.range(of: "await messagesLoaded"))
        XCTAssertLessThan(asyncLet.lowerBound, override.lowerBound, "message load must be in flight before the appearance/vault reads")
        XCTAssertLessThan(override.lowerBound, awaited.lowerBound)
    }
}
