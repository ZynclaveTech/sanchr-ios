import Foundation
import XCTest

@testable import Sanchr

final class PendingCallAndAvatarTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// AppRouter.pendingCallId was written by the Answer notification action
    /// and read by nothing.
    func testTheCallsTabAnswersAPendingIncomingCall() throws {
        let view = try source("Features/Calls/Presentation/CallsListView.swift")
        XCTAssertTrue(view.contains(".task(id: router.pendingCallId) {"))
        XCTAssertTrue(view.contains("try? await container.callManager.requestAnswerCall()"))
        XCTAssertTrue(view.contains("router.clearPendingCall()"))
    }

    /// A failed avatar upload used to be swallowed and the profile saved
    /// without the photo.
    func testAFailedAvatarUploadStopsAndExplains() throws {
        let viewModel = try source("Features/Onboarding/Presentation/OnboardingViewModel.swift")
        XCTAssertFalse(viewModel.contains("continuing without avatar"))
        XCTAssertTrue(viewModel.contains("errorMessage = \"Couldn't upload your photo. Try again, or remove it to continue without one.\""))
        let step = try source("Features/Onboarding/Presentation/OnboardingAvatarStepView.swift")
        XCTAssertTrue(step.contains("Button(\"Remove photo\")"))
    }
}
