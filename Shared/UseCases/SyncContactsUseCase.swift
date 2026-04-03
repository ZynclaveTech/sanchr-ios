import Foundation
import Contacts

/// Legacy use case for syncing device contacts with the Sanchr server.
/// Delegates to the ContactUseCases.SyncContacts use case via ContactDataSource.
/// Retained for backward compatibility with call sites that reference this type directly.
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
                if !normalized.isEmpty {
                    phoneNumbers.append(normalized)
                }
            }
        }

        SanchrLogger.sync.info("Found \(phoneNumbers.count) phone numbers on device")

        // 3. Sync with server via repository
        return try await contactRepository.syncDeviceContacts(phoneNumbers: phoneNumbers)
    }
}
