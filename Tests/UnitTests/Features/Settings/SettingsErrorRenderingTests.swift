import Foundation
import XCTest

@testable import Sanchr

/// Every settings screen that can set `errorMessage` must also show it.
///
/// Privacy, Security, Appearance, Chat Settings and the root screen all
/// wrote to `errorMessage` on a failed load or save and none of them
/// rendered it, so a toggle would silently revert with no explanation.
final class SettingsErrorRenderingTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Settings/Presentation/\(name).swift"),
            encoding: .utf8
        )
    }

    func testEveryScreenThatSyncsSettingsRendersTheError() throws {
        for name in ["PrivacyView", "SecurityView", "AppearanceView", "ChatSettingsView", "SettingsView"] {
            XCTAssertTrue(
                try source(name).contains("SettingsErrorLabel(message: viewModel.errorMessage)"),
                "\(name) sets errorMessage but does not show it"
            )
        }
    }

    @MainActor
    func testTheLabelRendersNothingForNil() {
        let renderer = ImageRenderer(content: SettingsErrorLabel(message: nil).fixedSize())
        XCTAssertNil(renderer.uiImage, "a nil message must not take up space")
    }
}
