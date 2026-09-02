import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// Someone saved in the user's own address book reads by that name — not
/// by the "~name" they assert about themselves. The top slot in the title
/// rule was reserved for this and never fed.
final class AddressBookNameTests: XCTestCase {

    private func user(_ id: String, name: String = User.serverPlaceholderDisplayName, phone: String = "",
                      saved: String? = nil) -> User {
        User(id: id, phoneNumber: phone, displayName: name, isVerified: true, status: .offline, addressBookName: saved)
    }

    func testTheSavedNameWinsWithoutATilde() {
        let participant = user("p", name: "Sooraj Sim", phone: "+919999999999")
        let contact = user("p", name: "Sooraj Sim", phone: "+919999999999", saved: "Sooraj (work)")
        XCTAssertEqual(MessageRepositoryImpl.displayTitle(for: participant, contact: contact), "Sooraj (work)")
    }

    func testWithoutASavedNameTheOldOrderHolds() {
        let participant = user("p", name: "Sooraj Sim", phone: "+919999999999")
        XCTAssertEqual(MessageRepositoryImpl.displayTitle(for: participant, contact: nil), "+919999999999")
        let noPhone = user("p", name: "Sooraj Sim")
        XCTAssertEqual(MessageRepositoryImpl.displayTitle(for: noPhone, contact: nil), "~Sooraj Sim")
    }

    /// Conversation saves and profile resolves write the same row with no
    /// address-book name; they must not erase the one the sync stored.
    func testALaterSaveWithoutTheNameKeepsIt() async throws {
        let database = try LocalDatabase(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("abn-\(UUID().uuidString).sqlite"),
            passphraseProvider: { "unit-test-passphrase" }
        )
        try await database.saveContact(user("p", name: "Sooraj Sim", phone: "+919999999999", saved: "Sooraj (work)"))
        try await database.saveContact(user("p", name: User.serverPlaceholderDisplayName, phone: "+919999999999"))

        let stored = try await database.fetchContacts().first { $0.id == "p" }
        XCTAssertEqual(stored?.addressBookName, "Sooraj (work)")
        XCTAssertEqual(stored?.displayName, "Sooraj Sim", "the resolved name is kept as before")
    }

    func testTheSyncCapturesCardNamesForTheMatches() throws {
        let useCases = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Contacts/Domain/ContactUseCases.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(useCases.contains("let cardName = [contact.givenName, contact.familyName]"))
        XCTAssertTrue(useCases.contains("syncContacts(phoneHashes: hashes, addressBookNames: namesByNumber)"))
    }
}
