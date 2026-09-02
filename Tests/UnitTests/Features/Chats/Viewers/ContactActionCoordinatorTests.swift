import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ContactActionCoordinatorTests: XCTestCase {
    func test_present_setsResolvedUserForRegisteredContact() async {
        let coordinator = ContactActionCoordinator(
            contactRepository: MockContactRepository(
                contacts: [Self.makeUser(id: "peer-1", phone: "+15551234")]
            ),
            deviceContactMatcher: { number in number == "+15551234" },
            currentUserId: { "self-user" },
            phoneNormalizer: { $0.replacingOccurrences(of: " ", with: "") }
        )

        await coordinator.present(name: "Alice", phoneNumber: "+15551234")

        XCTAssertEqual(coordinator.pendingContact?.resolvedSanchrUserId, "peer-1")
        XCTAssertEqual(coordinator.pendingContact?.normalizedPhone, "+15551234")
        XCTAssertEqual(coordinator.pendingContact?.alreadyInDeviceContacts, true)
        XCTAssertEqual(coordinator.pendingContact?.isSelfContact, false)
    }

    func test_present_hidesSanchrActionForSelfContact() async {
        let coordinator = ContactActionCoordinator(
            contactRepository: MockContactRepository(
                contacts: [Self.makeUser(id: "self-user", phone: "+15550000")]
            ),
            deviceContactMatcher: { _ in false },
            currentUserId: { "self-user" },
            phoneNormalizer: { $0 }
        )

        await coordinator.present(name: "Me", phoneNumber: "+15550000")

        XCTAssertNil(coordinator.pendingContact?.resolvedSanchrUserId)
        XCTAssertEqual(coordinator.pendingContact?.isSelfContact, true)
    }

    func test_present_leavesResolvedUserNilForUnknownContact() async {
        let coordinator = ContactActionCoordinator(
            contactRepository: MockContactRepository(contacts: []),
            deviceContactMatcher: { _ in false },
            currentUserId: { nil },
            phoneNormalizer: { $0 }
        )

        await coordinator.present(name: "Unknown", phoneNumber: "+19990000")

        XCTAssertNil(coordinator.pendingContact?.resolvedSanchrUserId)
        XCTAssertEqual(coordinator.pendingContact?.alreadyInDeviceContacts, false)
        XCTAssertEqual(coordinator.pendingContact?.isSelfContact, false)
    }

    private static func makeUser(id: String, phone: String) -> User {
        User(
            id: id,
            phoneNumber: phone,
            displayName: id,
            isVerified: true,
            status: .online
        )
    }
}

private final class MockContactRepository: ContactRepositoryProtocol, @unchecked Sendable {
    let contacts: [User]

    init(contacts: [User]) {
        self.contacts = contacts
    }

    func fetchContacts() async throws -> [User] {
        contacts
    }

    func syncDeviceContacts(phoneNumbers: [String]) async throws -> [User] {
        contacts.filter { phoneNumbers.contains($0.phoneNumber) }
    }

    func updateProfile(
        displayName: String?,
        bio: String?,
        avatarData: Data?
    ) async throws -> User {
        contacts.first ?? User.placeholder
    }
}
