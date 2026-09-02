import Foundation
import XCTest

@testable import Sanchr

/// Three pieces of behaviour that were written and never called.
final class DormantFeatureWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// Client-side AccessK expiry: started at launch, run on every
    /// foreground, stopped on sign-out.
    func testTheEKFPurgeRunsAndStops() throws {
        let app = try source("App/SanchrApp.swift")
        XCTAssertTrue(app.contains("container.ekfNotificationListener.startPeriodicPurge()"))
        XCTAssertEqual(app.components(separatedBy: "ekfNotificationListener.purgeExpiredKeys()").count - 1, 2,
                       "purge at launch and on every foreground")
        let container = try source("App/DependencyContainer.swift")
        let wipe = try XCTUnwrap(container.range(of: "func wipeLocalSessionArtifacts() async {"))
        XCTAssertTrue(String(container[wipe.upperBound...].prefix(300)).contains("ekfNotificationListener.stop()"))
    }

    /// The chats list's syncing indicator and post-sync refresh read a
    /// SyncState the view never handed over.
    func testTheChatsListObservesSyncState() throws {
        let view = try source("Features/Chats/Presentation/ChatsListView.swift")
        XCTAssertTrue(view.contains("@Environment(SyncState.self) private var syncState"))
        XCTAssertTrue(view.contains("viewModel.observeSyncState(syncState)"))
        XCTAssertTrue(view.contains(".onChange(of: syncState.lastSyncTimestamp)"))
        XCTAssertTrue(view.contains("viewModel.refreshIfSyncCompleted(messageRepository:"))
    }

    /// Every RTCMTLVideoView SwiftUI discards must stop being rendered into.
    func testDiscardedVideoViewsDetachTheirRenderer() throws {
        let view = try source("Features/Calls/Presentation/ActiveCallView.swift")
        XCTAssertTrue(view.contains("coordinator.callManager?.detachLocalRenderer(uiView)"))
        XCTAssertTrue(view.contains("coordinator.callManager?.detachRemoteRenderer(uiView)"))
        XCTAssertFalse(view.contains("// Renderer will be cleaned up when CallManager closes WebRTC"))
    }
}
