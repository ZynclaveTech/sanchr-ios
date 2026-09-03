import XCTest
@testable import Sanchr

/// Phase 7 of the readiness plan: onboarding resumes where it was killed,
/// notifications are asked for with a reason and can be asked for again,
/// and contact discovery is reachable after onboarding.
@MainActor
final class OnboardingPhase7Tests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "OnboardingPhase7Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testProgressSurvivesAKill() {
        let defaults = freshDefaults()
        let first = OnboardingViewModel(defaults: defaults)
        first.displayName = "Sooraj"
        first.goToNextStep()
        first.goToNextStep()
        XCTAssertEqual(first.currentStep, 3)

        // A new instance is what a relaunch creates.
        let resumed = OnboardingViewModel(defaults: defaults)
        XCTAssertEqual(resumed.currentStep, 3, "resumes at the step the user reached")
        XCTAssertEqual(resumed.displayName, "Sooraj", "the typed name is not lost")

        resumed.finish()
        let after = OnboardingViewModel(defaults: defaults)
        XCTAssertEqual(after.currentStep, 1)
        XCTAssertEqual(after.displayName, "")
    }

    func testStoredStepIsClampedToTheFlow() {
        let defaults = freshDefaults()
        defaults.set(99, forKey: "sanchr.onboarding.step")
        XCTAssertEqual(OnboardingViewModel(defaults: defaults).currentStep, OnboardingViewModel.totalSteps)
        defaults.set(-4, forKey: "sanchr.onboarding.step")
        XCTAssertEqual(OnboardingViewModel(defaults: defaults).currentStep, 1)
    }

    func testTheFlowHasFourStepsWithNotificationsBeforeContacts() throws {
        XCTAssertEqual(OnboardingViewModel.totalSteps, 4)
        let container = try source("Features/Onboarding/Presentation/OnboardingView.swift")
        let notifications = try XCTUnwrap(container.range(of: "case 3:\n                OnboardingNotificationsStepView("))
        let contacts = try XCTUnwrap(container.range(of: "case 4:\n                OnboardingContactSyncStepView("))
        XCTAssertLessThan(notifications.lowerBound, contacts.lowerBound)
        XCTAssertTrue(container.contains("viewModel.finish()"), "finishing clears the resume point")
        for step in ["OnboardingNameStepView", "OnboardingAvatarStepView"] {
            let text = try source("Features/Onboarding/Presentation/\(step).swift")
            XCTAssertTrue(text.contains("OF \\(OnboardingViewModel.totalSteps)"), "\(step) hardcoded the step count")
        }
    }

    func testNotificationsAreAskedForWithAReasonNotAsASideEffect() throws {
        let contactStep = try source("Features/Onboarding/Presentation/OnboardingContactSyncStepView.swift")
        XCTAssertFalse(contactStep.contains("requestNotificationPermission"), "the contact step no longer burns the one-shot prompt")
        let step = try source("Features/Onboarding/Presentation/OnboardingNotificationsStepView.swift")
        XCTAssertTrue(step.contains("Turn on notifications"))
        XCTAssertTrue(step.contains("requestNotificationPermission(pushManager: pushManager)"))
        XCTAssertTrue(step.contains("Button(\"Not now\")"))
    }

    func testTheOneShotPromptCanStillBeShownLater() throws {
        let push = try source("Platform/Notifications/PushManager.swift")
        XCTAssertTrue(push.contains("func requestAuthorizationIfUndetermined() async -> Bool"))
        XCTAssertTrue(push.contains("authorizationStatus == .notDetermined"))
        let app = try source("App/SanchrApp.swift")
        XCTAssertTrue(app.contains(".task { await container.pushManager.requestAuthorizationIfUndetermined() }"),
                      "a force-quit during onboarding must not leave the app without push")
        let notifications = try source("Features/Settings/Presentation/NotificationsView.swift")
        XCTAssertTrue(notifications.contains("if viewModel.systemPermissionUndetermined {"))
        XCTAssertTrue(notifications.contains("await container.pushManager.requestAuthorization()"))
    }

    func testContactDiscoveryIsReachableFromContacts() throws {
        let contacts = try source("Features/Contacts/Presentation/ContactsView.swift")
        XCTAssertTrue(contacts.contains("Find friends from contacts"))
        XCTAssertTrue(contacts.contains("ContactSyncView()"), "the sync screen used to have onboarding as its only entry point")
        XCTAssertFalse(contacts.contains("after onboarding sync and discovery"))
    }
}
