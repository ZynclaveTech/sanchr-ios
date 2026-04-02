import Foundation
import Contacts

/// Use case for syncing device contacts with the Sanchr server.
/// Hashes phone numbers before sending for privacy.
struct SyncContactsUseCase: Sendable {
    private let contactRepository: ContactRepositoryProtocol

    init(contactRepository: ContactRepositoryProtocol) {
        self.contactRepository = contactRepository
    }

    /// Requests contact access, extracts phone numbers, and syncs with server.
    func execute() async throws -> [User] {
        // 1. Request Contacts permission
        let store = CNContactStore()
        let authorized = try await store.requestAccess(for: .contacts)

        guard authorized else {
            SanchrLogger.sync.warning("Contact access denied")
            return []
        }

        // 2. Fetch device contacts
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var phoneNumbers: [String] = []

        try store.enumerateContacts(with: request) { contact, _ in
            for number in contact.phoneNumbers {
                let normalized = number.value.stringValue
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                phoneNumbers.append(normalized)
            }
        }

        SanchrLogger.sync.info("Found \(phoneNumbers.count) phone numbers on device")

        // 3. Sync with server (server-side hashing for discovery)
        return try await contactRepository.syncDeviceContacts(phoneNumbers: phoneNumbers)
    }
}
