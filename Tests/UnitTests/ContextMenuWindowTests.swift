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

    private func hostWindow() throws -> UIWindow {
        try XCTUnwrap(
            MessageContextMenuWindow.host,
            "no foreground key window; this test needs the app host"
        )
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
