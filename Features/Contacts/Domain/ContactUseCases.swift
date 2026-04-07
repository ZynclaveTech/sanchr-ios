import Contacts
import CryptoKit
import Foundation
import SanchrShared

/// Domain use cases for contact operations.
enum ContactUseCases {

    /// Syncs device contacts with the Sanchr server using SHA-256 hashed phone numbers.
    struct SyncContacts: Sendable {
        private let contactDataSource: ContactDataSource

        init(contactDataSource: ContactDataSource) {
            self.contactDataSource = contactDataSource
        }

        /// Requests contact access, hashes phone numbers with SHA-256, and calls SyncContacts RPC.
        func execute() async throws -> [User] {
            // 1. Request Contacts permission
            let store = CNContactStore()
            let authorized = try await store.requestAccess(for: .contacts)

            guard authorized else {
                SanchrLogger.sync.warning("Contact access denied by user")
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

            guard !phoneNumbers.isEmpty else { return [] }

            // 3. Hash phone numbers with SHA-256 for privacy
            let hashes = phoneNumbers.map { ContactDataSource.hashPhoneNumber($0) }

            // 4. Send hashes to server
            return try await contactDataSource.syncContacts(phoneHashes: hashes)
        }
    }

    /// Fetches the user's contact list from the server with local caching.
    struct GetContacts: Sendable {
        private let contactDataSource: ContactDataSource
        private let localDatabase: LocalDatabaseProtocol

        init(contactDataSource: ContactDataSource, localDatabase: LocalDatabaseProtocol) {
            self.contactDataSource = contactDataSource
            self.localDatabase = localDatabase
        }

        /// Fetches contacts from the server. Falls back to local cache on failure.
        func execute() async throws -> [User] {
            do {
                let serverContacts = try await contactDataSource.getContacts()
                return serverContacts
            } catch {
                SanchrLogger.sync.warning(
                    "Server fetch failed, falling back to local cache: \(error.localizedDescription)"
                )
                return try await localDatabase.fetchContacts()
            }
        }
    }

    /// Blocks a contact by user ID.
    struct BlockContact: Sendable {
        private let contactDataSource: ContactDataSource

        init(contactDataSource: ContactDataSource) {
            self.contactDataSource = contactDataSource
        }

        func execute(userId: String) async throws {
            try await contactDataSource.blockContact(userId: userId)
        }
    }

    /// Unblocks a previously blocked contact.
    struct UnblockContact: Sendable {
        private let contactDataSource: ContactDataSource

        init(contactDataSource: ContactDataSource) {
            self.contactDataSource = contactDataSource
        }

        func execute(userId: String) async throws {
            try await contactDataSource.unblockContact(userId: userId)
        }
    }

    /// Fetches the blocked contact list.
    struct GetBlockedList: Sendable {
        private let contactDataSource: ContactDataSource

        init(contactDataSource: ContactDataSource) {
            self.contactDataSource = contactDataSource
        }

        func execute() async throws -> [String] {
            try await contactDataSource.getBlockedList()
        }
    }
}
