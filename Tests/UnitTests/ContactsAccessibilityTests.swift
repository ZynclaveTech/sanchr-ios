import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Contacts had no accessibility labels at all, and refusing the address book
/// produced an empty list with no explanation.
final class ContactsAccessibilityTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheIconOnlyControlsAreLabelled() throws {
        let view = try source("Features/Contacts/Presentation/ContactsView.swift")
        for label in ["\"Add contact\"", "\"Clear search\""] {
            XCTAssertTrue(view.contains(label), "missing an accessibility label for \(label)")
        }
    }

    /// A contact row is one thing that opens a chat, not a name followed by a
    /// bare shield followed by a phone number with no hint any of it is
    /// tappable.
    func testAContactRowReadsAsASingleControl() throws {
        let view = try source("Features/Contacts/Presentation/ContactsView.swift")
        XCTAssertTrue(view.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(view.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(
            view.contains(", verified"),
            "the shield is silent to VoiceOver unless the label says so"
        )
    }

    // MARK: - Permission

    /// Returning an empty list was indistinguishable from "you know nobody on
    /// Sanchr": the sync reported success and the reason sat in a log line.
    func testRefusingTheAddressBookIsAnError() throws {
        let useCase = try source("Features/Contacts/Domain/ContactUseCases.swift")
        let guardBody = try XCTUnwrap(
            useCase.range(of: "guard authorized else {").map {
                String(useCase[$0.upperBound...].prefix(500))
            }
        )
        XCTAssertTrue(
            guardBody.contains("throw AppError.contactsPermissionDenied"),
            "a refusal must surface, not return an empty list"
        )
    }

    /// The app cannot ask twice, so the message has to name the way out.
    func testTheMessagePointsToSettings() {
        let message = AppError.contactsPermissionDenied.localizedDescription
        XCTAssertTrue(message.lowercased().contains("settings"))
        XCTAssertTrue(message.lowercased().contains("contacts"))
    }

    /// And offers a route there — but only for a refusal. Sending someone to
    /// Settings to fix a network error would waste the trip.
    func testSettingsIsOfferedOnlyForARefusal() throws {
        let view = try source("Features/Contacts/Presentation/ContactSyncView.swift")
        XCTAssertTrue(view.contains("openSettingsURLString"))
        XCTAssertTrue(
            view.contains("if needsSettings {"),
            "the Settings button must be gated on the failure actually being a refusal"
        )
    }
}
