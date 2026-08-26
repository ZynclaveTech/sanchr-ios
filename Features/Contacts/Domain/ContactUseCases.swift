import Contacts
import GRPC
import CryptoKit
import Foundation
import SanchrShared

/// Domain use cases for contact operations.
enum ContactUseCases {

    /// Discovers which device contacts are Sanchr users via OPRF-PSI, then resolves
    /// only the matches to user records.
    ///
    /// The address book previously went to the server as unsalted `SHA-256(e164)`
    /// hashes. Phone numbers are a small, structured space, so those hashes are
    /// trivially reversible: the server learned the caller's entire contact list.
    ///
    /// Now the whole address book is evaluated through the OPRF, where the server
    /// sees only blinded Ristretto255 points and learns nothing about which numbers
    /// were queried. Only the numbers that actually matched are then resolved to
    /// user records, so the server observes the intersection — the people you are
    /// about to be able to message — instead of everyone you have ever met.
    struct SyncContacts: Sendable {
        private let contactDataSource: ContactDataSource
        private let discoveryRepository: DiscoveryRepositoryProtocol

        init(
            contactDataSource: ContactDataSource,
            discoveryRepository: DiscoveryRepositoryProtocol
        ) {
            self.contactDataSource = contactDataSource
            self.discoveryRepository = discoveryRepository
        }

        /// Requests contact access, runs OPRF discovery, and resolves matches.
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
                    // Use the shared normalizer so the string we blind is byte-identical
                    // to the one the server hashed when it built the registered set.
                    // A second, slightly different normalizer here would silently
                    // produce zero matches.
                    let normalized = ContactDataSource.normalizePhoneNumber(
                        number.value.stringValue)
                    if !normalized.isEmpty {
                        phoneNumbers.append(normalized)
                    }
                }
            }

            // De-duplicate: the same number often appears on several contact cards,
            // and every duplicate is another point the server has to evaluate.
            phoneNumbers = Array(Set(phoneNumbers))

            SanchrLogger.sync.info("Found \(phoneNumbers.count) phone numbers on device")

            guard !phoneNumbers.isEmpty else { return [] }

            // 3. OPRF-PSI: determine which numbers are registered without telling the
            // server which numbers we asked about. Deliberately no fallback to the
            // legacy hash upload — falling back would leak the whole address book,
            // which is the thing this exists to prevent. Better to fail the sync.
            let matched: [String]
            do {
                matched = try await discoveryRepository.discoverContacts(
                    phoneNumbers: phoneNumbers)
            } catch let status as GRPCStatus where status.code == .unavailable {
                // The server returns UNAVAILABLE when discovery.oprf_enabled is
                // false or no OPRF secret is configured. Without this, the failure
                // surfaced as "GRPC.GRPCStatus error 1", which names neither the
                // real status code nor the cause.
                SanchrLogger.sync.error(
                    "OPRF discovery unavailable: \(SignalSessionManager.detailedError(status))")
                throw AppError.featureDisabled(feature: "contact_discovery")
            }

            SanchrLogger.sync.info(
                "OPRF discovery matched \(matched.count) of \(phoneNumbers.count) numbers")

            guard !matched.isEmpty else { return [] }

            // 4. Resolve only the matches to user records. The server necessarily
            // learns this set — it has to, to return the accounts — but that is the
            // intersection, not the address book.
            let hashes = matched.map { ContactDataSource.hashPhoneNumber($0) }
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
