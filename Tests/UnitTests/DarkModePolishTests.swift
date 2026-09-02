import Foundation
import SwiftUI
import XCTest

@testable import Sanchr

final class DarkModePolishTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// Black at a light-mode opacity disappears on a dark surface.
    func testAdHocShadowsGoThroughTheThemeAwareModifier() throws {
        var remaining: [String] = []
        for path in ["Features/Auth/Presentation/LoginView.swift", "Features/Chats/Presentation/ChatInputBarView.swift",
                     "Features/Chats/Presentation/ConversationRow.swift", "Features/Chats/Presentation/ContextMenu/MessageContextActionList.swift"] {
            let text = try source(path)
            if text.contains("shadow(color: Color.black") || text.contains("shadow(color: .black") { remaining.append(path) }
            XCTAssertTrue(text.contains(".sanchrShadow("), path)
        }
        XCTAssertTrue(remaining.isEmpty, "still using a flat black shadow: \(remaining)")
    }

    func testTheShadowModifierDeepensInDarkMode() throws {
        let shadows = try source("SanchrShared/DesignSystem/Shadows.swift")
        XCTAssertTrue(shadows.contains("colorScheme == .dark ? min(lightOpacity * 4, 0.6) : lightOpacity"))
    }

    /// The security-event pill was cream-on-amber in both schemes.
    func testTheSecurityEventPillHasADarkPalette() throws {
        let bubble = try source("Features/Chats/Presentation/MessageBubble.swift")
        for token in ["securityEventIconDark", "securityEventTextDark", "securityEventBgDark", "securityEventBorderDark"] {
            XCTAssertTrue(bubble.contains(token), token)
        }
    }

    func testTheForwardFooterAnimatesItsTransition() throws {
        let picker = try source("Features/Chats/Presentation/MessageForwardDestinationPicker.swift")
        XCTAssertTrue(picker.contains(".animation(.easeInOut(duration: 0.22), value: selected.isEmpty)"))
    }
}
