import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

final class ProfileNameAndThemeDefaultTests: XCTestCase {

    /// The root view treats a nameless session as unfinished onboarding, so
    /// saving an empty name ejected the user back to the name screen.
    @MainActor
    func testAnEmptyNameCannotBeSaved() {
        let viewModel = ProfileViewModel()
        viewModel.displayName = "   "
        XCTAssertFalse(viewModel.hasDisplayName)
        viewModel.displayName = " Asha "
        XCTAssertTrue(viewModel.hasDisplayName)
    }

    func testTheSaveButtonIsGatedOnAName() throws {
        let view = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Profile/Presentation/ProfileView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(view.contains("|| !viewModel.hasDisplayName)"))
    }

    /// A forced light default gave every dark-mode user a white app on first
    /// launch.
    func testTheThemeFollowsTheSystemUntilChosen() {
        XCTAssertEqual(SanchrTheme().mode, .system)
    }
}
