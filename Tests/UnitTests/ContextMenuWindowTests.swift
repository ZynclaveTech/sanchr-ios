import SwiftUI
import UIKit
import XCTest

@testable import Sanchr

/// Drives `MessageContextMenuWindow` for real, rather than asserting on the
/// shape of its source.
///
/// What matters is the state the chat window is left in: reachable by
/// VoiceOver before the menu opens, hidden from it while the menu is up, and
/// reachable again afterwards. A leak in the last step is the worst of the
/// three — it leaves the conversation permanently unreadable.
@MainActor
final class ContextMenuWindowTests: XCTestCase {

    /// The host window, once the test host has actually come to the front.
    ///
    /// `MessageContextMenuWindow.host` requires a `foregroundActive` scene,
    /// and the host app is not yet active when the first test in a run
    /// starts. That made these three pass or fail depending on where they
    /// landed in the order — adding tests elsewhere in the suite was enough
    /// to flip them, which is the worst kind of red build: real-looking and
    /// unrelated to the change.
    ///
    /// Spin the runloop until the scene activates rather than asserting on
    /// the first sample. If it never activates the environment cannot host
    /// these at all, so skip rather than fail — a headless run should not
    /// report a UI regression it did not observe.
    private func hostWindow() throws -> UIWindow {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let host = MessageContextMenuWindow.host {
                return host
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw XCTSkip("no foreground key window; this environment cannot host the app's window")
    }

    func testTheChatIsHiddenFromVoiceOverOnlyWhileTheMenuIsUp() throws {
        let host = try hostWindow()
        host.accessibilityElementsHidden = false

        let menu = MessageContextMenuWindow()
        menu.present(Text("menu"), colorScheme: .dark)

        XCTAssertTrue(
            host.accessibilityElementsHidden,
            "the blurred chat must not be reachable while the menu is open"
        )

        menu.dismiss()

        XCTAssertFalse(
            host.accessibilityElementsHidden,
            "the conversation has to come back, or it is unreadable from here on"
        )
    }

    /// Presenting twice must not strand the flag. The second present calls
    /// dismiss first, and if that restored a stale reference the chat could be
    /// left hidden with no menu on screen.
    func testPresentingTwiceStillRestoresTheChat() throws {
        let host = try hostWindow()
        host.accessibilityElementsHidden = false

        let menu = MessageContextMenuWindow()
        menu.present(Text("first"), colorScheme: .dark)
        menu.present(Text("second"), colorScheme: .dark)

        XCTAssertTrue(host.accessibilityElementsHidden)

        menu.dismiss()

        XCTAssertFalse(
            host.accessibilityElementsHidden,
            "a re-present must not leave the chat hidden after the menu closes"
        )
    }

    /// Dismissing something that was never presented must not hide anything.
    func testDismissingWithoutPresentingChangesNothing() throws {
        let host = try hostWindow()
        host.accessibilityElementsHidden = false

        MessageContextMenuWindow().dismiss()

        XCTAssertFalse(host.accessibilityElementsHidden)
    }
}
