import Foundation

/// Domain use cases for contact operations.
enum ContactUseCases {

    /// Fetches the user's Sanchr contact list.
    struct FetchContacts: Sendable {
        private let contactRepository: ContactRepositoryProtocol

        init(contactRepository: ContactRepositoryProtocol) {
            self.contactRepository = contactRepository
        }

        func execute() async throws -> [User] {
            try await contactRepository.fetchContacts()
        }
    }

    /// Blocks a contact.
    struct BlockContact: Sendable {
        private let contactRepository: ContactRepositoryProtocol

        init(contactRepository: ContactRepositoryProtocol) {
            self.contactRepository = contactRepository
        }

        func execute(userId: String) async throws {
            try await contactRepository.blockUser(userId: userId)
        }
    }
}
