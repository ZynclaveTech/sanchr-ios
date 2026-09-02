import Foundation
import XCTest

@testable import Sanchr

/// Every icon-only button on the settings, vault and profile screens must
/// tell VoiceOver what it does.
final class IconButtonLabelTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testIconOnlyButtonsCarryLabels() throws {
        let expectations: [(String, [String])] = [
            ("Features/Settings/Presentation/PINEntryView.swift", ["Back", "Delete last digit"]),
            ("Features/Vault/Presentation/VaultView.swift", ["Dismiss failed upload", "More options"]),
            ("Features/Profile/Presentation/ProfileView.swift", ["Save QR code"]),
        ]
        for (path, labels) in expectations {
            let text = try source(path)
            for label in labels {
                XCTAssertTrue(text.contains(".accessibilityLabel(\"\(label)\")"), "\(path) lacks \(label)")
            }
        }
    }
}
