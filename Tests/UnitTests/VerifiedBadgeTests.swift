import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// The shield badge must mean "I have verified this person's identity key",
/// not "this person has an account".
///
/// `User.isVerified` is a registration flag despite the name — the persistence
/// layer reads it as `isRegistered`, and contact discovery sets it true for
/// everyone it matches, because matching is what proves they are registered.
/// Four screens drew a security shield from it, so every contact appeared
/// verified and the badge could never warn anyone. In a product whose whole
/// claim is verifiable identity, a badge that is always on is worse than none.
final class VerifiedBadgeTests: XCTestCase {

    private static let shieldViews = [
        "Features/Contacts/Presentation/ContactsView.swift",
        "Features/Contacts/Presentation/PhoneNumberLookupView.swift",
        "Features/Calls/Presentation/CallsListView.swift",
        "Features/Chats/Presentation/NewChatContactPicker.swift",
    ]

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Strips comments, so the note explaining the bug cannot satisfy the
    /// guard against it — a trap this repo has walked into twice.
    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testNoShieldIsDrawnFromTheRegistrationFlag() throws {
        for relative in Self.shieldViews {
            let body = code(try source(relative))
            XCTAssertFalse(
                body.contains("contact.isVerified") || body.contains("user.isVerified"),
                "\(relative) still draws a badge from the registration flag"
            )
        }
    }

    /// Every shield site has to be fed by the identity store instead.
    func testEveryShieldSiteAsksTheIdentityStore() throws {
        for relative in Self.shieldViews {
            let body = try source(relative)
            XCTAssertTrue(
                body.contains("isIdentityVerified"),
                "\(relative) draws a shield but never consults identity verification"
            )
        }
    }

    /// Registration still has to be recorded — discovery depends on it, and the
    /// point was to stop *rendering* it as a security claim, not to stop
    /// tracking it.
    func testRegistrationIsStillRecorded() {
        let matched = User(
            id: "u1",
            phoneNumber: "+919569740653",
            displayName: "A",
            isVerified: true,
            status: .offline
        )
        XCTAssertTrue(matched.isVerified, "discovery still marks matched contacts as registered")
    }

    /// The name is the trap, so it carries a warning that points at the real
    /// question. Losing it is how this comes back.
    func testTheModelWarnsAgainstUsingItAsASecuritySignal() throws {
        let model = try source("SanchrShared/Models/User.swift")
        XCTAssertTrue(model.contains("isIdentityVerified"))
        XCTAssertTrue(model.lowercased().contains("registration"))
    }
}
