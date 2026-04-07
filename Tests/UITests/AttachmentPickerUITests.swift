import XCTest

final class AttachmentPickerUITests: XCTestCase {

    @MainActor
    func testTappingPlusButtonPresentsAttachmentPicker() throws {
        // TODO: The current UI test target has no launch-arg hook to deep-link
        // into an authenticated chat (see Tests/UITests/SanchrUITests.swift).
        // Adding such a hook would require modifying production code, which is
        // out of scope for Task 16. Re-enable this test once a
        // `-uiTestAuthenticatedFakeChat` (or equivalent) launch hook exists.
        try XCTSkipUnless(false, "No chat-launch UI test hook available; see TODO.")

        let app = XCUIApplication()
        app.launchArguments += ["-uiTestAuthenticatedFakeChat"]
        app.launch()

        // Tap composer plus button (assumes it exposes an a11y label or image).
        let plus = app.buttons["plus"].firstMatch
        if !plus.exists { app.images["plus"].firstMatch.tap() } else { plus.tap() }

        let vault = app.otherElements["attachmentPicker.actionGrid.vault"]
        XCTAssertTrue(vault.waitForExistence(timeout: 3.0))
    }

    @MainActor
    func testAttachmentPickerActionGridA11yLabels() throws {
        // TODO: Same blocker as above. This test will assert each tile's
        // VoiceOver label once the picker can be presented from a UI test.
        try XCTSkipUnless(false, "No chat-launch UI test hook available; see TODO.")

        let app = XCUIApplication()
        app.launchArguments += ["-uiTestAuthenticatedFakeChat"]
        app.launch()

        let vault = app.otherElements["attachmentPicker.actionGrid.vault"]
        let file = app.otherElements["attachmentPicker.actionGrid.file"]
        let contact = app.otherElements["attachmentPicker.actionGrid.contact"]
        let location = app.otherElements["attachmentPicker.actionGrid.location"]

        XCTAssertEqual(vault.label, "Vault, encrypted")
        XCTAssertEqual(file.label, "Files")
        XCTAssertEqual(contact.label, "Contact")
        XCTAssertEqual(location.label, "Location")
    }
}
