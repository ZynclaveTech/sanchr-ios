import UIKit
import XCTest
@testable import Sanchr

/// Every settings screen shares one ground, every row is tappable across
/// its whole face, and every Help Center icon resolves.
final class SettingsConsistencyTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let screens = root.appendingPathComponent("Features/Settings/Presentation")

    private func screenSources() throws -> [(String, String)] {
        try FileManager.default.contentsOfDirectory(at: Self.screens, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("View.swift") }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNoSubscreenPaintsItsOwnDifferentGround() throws {
        for (name, text) in try screenSources() where name != "SettingsView.swift" {
            XCTAssertFalse(text.contains(".background(SanchrExportColors.surfaceSoft.ignoresSafeArea())"),
                           "\(name) paints the grouped surface over the shared ground; the tabs use `background`")
            XCTAssertFalse(text.contains(".navigationTitle(\""), "\(name) should use sanchrSettingsSubscreenNavigation, which paints the shared ground")
        }
        let settings = try String(contentsOf: Self.screens.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        let nav = try XCTUnwrap(settings.range(of: "func sanchrSettingsSubscreenNavigation(title: String) -> some View {"))
        XCTAssertTrue(String(settings[nav.upperBound...].prefix(300)).contains(".background(SanchrExportColors.background.ignoresSafeArea())"),
                      "the settings ground is the same colour the Chats, Calls and Contacts tabs paint")
        for tab in ["Features/Chats/Presentation/ChatsListView.swift", "Features/Calls/Presentation/CallsListView.swift", "Features/Contacts/Presentation/ContactsView.swift"] {
            let text = try String(contentsOf: Self.root.appendingPathComponent(tab), encoding: .utf8)
            XCTAssertTrue(text.contains(".background(SanchrExportColors.background)"), "\(tab) is the reference ground")
        }
    }

    func testEveryButtonLabelIsTappableAcrossItsWholeFace() throws {
        for (name, text) in try screenSources() {
            var searchStart = text.startIndex
            while let labelRange = text.range(of: "} label: {", range: searchStart..<text.endIndex) {
                var depth = 0
                var idx = text.index(before: labelRange.upperBound)
                var close = text.endIndex
                while idx < text.endIndex {
                    if text[idx] == "{" { depth += 1 } else if text[idx] == "}" { depth -= 1; if depth == 0 { close = idx; break } }
                    idx = text.index(after: idx)
                }
                let block = String(text[labelRange.lowerBound..<close])
                XCTAssertTrue(block.contains(".contentShape("), "\(name): a button label without a hit shape near \(block.prefix(60))")
                searchStart = close
            }
        }
        let primitives = try String(contentsOf: Self.screens.appendingPathComponent("SettingsPrimitives.swift"), encoding: .utf8)
        XCTAssertTrue(primitives.contains(".contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))"), "settingsCard")
    }

    func testHelpCenterIconsResolve() throws {
        let help = try String(contentsOf: Self.screens.appendingPathComponent("HelpCenterView.swift"), encoding: .utf8)
        XCTAssertFalse(help.contains("\"rocket\""), "rocket did not render on the user's device")
        // Icons live in the content model, one per article and category.
        for name in HelpContent.articles.map(\.icon) + HelpCategory.allCases.map(\.icon) {
            XCTAssertNotNil(UIImage(systemName: name), "Help Center uses a symbol that does not exist: \(name)")
        }
    }

    func testSettingsSearchesWithTheHomeTabsField() throws {
        let settings = try String(contentsOf: Self.screens.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("SanchrSearchField(placeholder: \"Search settings...\""))
        XCTAssertFalse(settings.contains(".searchable("), "the system search bar looked nothing like the tabs' field")
    }

    func testAppearanceRowReportsTheStoredTheme() throws {
        let settings = try String(contentsOf: Self.screens.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        let subtitle = try XCTUnwrap(settings.range(of: "private var themeSubtitle: String {"))
        let body = String(settings[subtitle.upperBound...].prefix(260))
        XCTAssertTrue(body.contains("SanchrTheme.Mode(rawValue: storedThemeMode)"), "the row must read the theme the app applies")
        XCTAssertTrue(body.contains("case .system: return \"System\""))
        XCTAssertFalse(body.contains("viewModel.theme"))
    }

    func testDarkCardsAreNeutralLikeTheHomeTabs() throws {
        let tokens = try String(contentsOf: Self.root.appendingPathComponent("SanchrShared/DesignSystem/ExportComponents.swift"), encoding: .utf8)
        let card = try XCTUnwrap(tokens.range(of: "public static let card = Color(uiColor: UIColor { traits in"))
        XCTAssertTrue(String(tokens[card.upperBound...].prefix(400)).contains("? UIColor.secondarySystemBackground"), "the brand's dark elevated surface has a blue cast")
    }
}

