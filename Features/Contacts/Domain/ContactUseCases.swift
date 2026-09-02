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
    /// Finds the account behind a phone number the user typed in.
    ///
    /// This used to upload a bare SHA-256 of the number through the legacy
    /// sync RPC. A phone number has ~10 digits of entropy, so that hash is
    /// the number as far as the server is concerned, and the manual lookup
    /// was the one path around the OPRF discovery the address-book sync
    /// insists on. It now asks the same way: OPRF first, and only a number
    /// the server confirmed as registered is then resolved to a user.
    struct LookupUser: Sendable {
        private let contactDataSource: ContactDataSource
        private let discoveryRepository: DiscoveryRepositoryProtocol

        init(contactDataSource: ContactDataSource, discoveryRepository: DiscoveryRepositoryProtocol) {
            self.contactDataSource = contactDataSource
            self.discoveryRepository = discoveryRepository
        }

        func execute(phoneNumber: String) async throws -> User? {
            let normalized = phoneNumber.replacingOccurrences(
                of: "[^0-9+]", with: "", options: .regularExpression)
            guard !normalized.isEmpty else { return nil }

            let matched: [String]
            do {
                matched = try await discoveryRepository.discoverContacts(phoneNumbers: [normalized])
            } catch let status as GRPCStatus where status.code == .unavailable {
                SanchrLogger.sync.error(
                    "OPRF discovery unavailable: \(SignalSessionManager.detailedError(status))")
                throw AppError.featureDisabled(feature: "contact_discovery")
            }
            guard matched.contains(normalized) else { return nil }

            let users = try await contactDataSource.syncContacts(
                phoneHashes: [ContactDataSource.hashPhoneNumber(normalized)])
            return users.first
        }
    }

    struct SyncContacts: Sendable {
        private let contactDataSource: ContactDataSource
        private let discoveryRepository: DiscoveryRepositoryProtocol

        /// The local user's own E.164 number.
        ///
        /// Both the calling code and the national number length are derived
        /// from it. Taking the whole number rather than just the code is what
        /// lets a locally-saved number be read unambiguously — see
        /// `ContactDataSource.nationalNumberLength(ofE164:)`.
        private let ownE164: @Sendable () -> String

        init(
            contactDataSource: ContactDataSource,
            discoveryRepository: DiscoveryRepositoryProtocol,
            ownE164: @escaping @Sendable () -> String = { "" }
        ) {
            self.contactDataSource = contactDataSource
            self.discoveryRepository = discoveryRepository
            self.ownE164 = ownE164
        }

        /// Requests contact access, runs OPRF discovery, and resolves matches.
        func execute() async throws -> [User] {
            // 1. Request Contacts permission
            let store = CNContactStore()
            let authorized = try await store.requestAccess(for: .contacts)

            guard authorized else {
                // Returning an empty list here was indistinguishable from
                // "you know nobody on Sanchr": the sync reported success, the
                // screen showed nothing, and the reason was in a log line
                // nobody reads.
                SanchrLogger.sync.warning("Contact access denied by user")
                throw AppError.contactsPermissionDenied
            }

            // 2. Fetch device contacts
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
            ]

            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            var phoneNumbers: [String] = []

            // Accounts are registered in E.164 ("+919569740653"), so that is the
            // only form that can match. Address-book entries are frequently
            // local ("9569740653", "095697 40653"), which is why a saved contact
            // could previously fail to match its own account and the sync
            // reported zero results.
            let own = ownE164()
            let callingCode = ContactDataSource.callingCode(fromE164: own)
            let nationalLength = ContactDataSource.nationalNumberLength(ofE164: own)
            try store.enumerateContacts(with: request) { contact, _ in
                for number in contact.phoneNumbers {
                    let raw = number.value.stringValue
                    if let e164 = ContactDataSource.e164PhoneNumber(
                        raw,
                        defaultCallingCode: callingCode,
                        nationalNumberLength: nationalLength)
                    {
                        phoneNumbers.append(e164)
                    }
                    // Also try the raw normalized form: it costs one extra
                    // blinded point and covers contacts already stored in the
                    // exact registered format when no calling code is known.
                    let normalized = ContactDataSource.normalizePhoneNumber(raw)
                    if !normalized.isEmpty, normalized.hasPrefix("+") {
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

        /// Returns the user's full contact list: phone-discovered contacts from
        /// the server AND peers that only exist locally — QR-paired contacts, whom
        /// the server's phone-number discovery never returns but who were resolved
        /// from a conversation and saved to the local table.
        func execute() async throws -> [User] {
            // Refresh from the server. This also persists server contacts into the
            // local table; the saveContact guard keeps any locally-resolved name
            // from being overwritten by the server's "Sanchr User" placeholder. On
            // failure the local cache already holds the last good server sync.
            do {
                _ = try await contactDataSource.getContacts()
            } catch {
                SanchrLogger.sync.warning(
                    "Server contact fetch failed, using local cache: \(error.localizedDescription)"
                )
            }
            let localContacts = (try? await localDatabase.fetchContacts()) ?? []
            return Self.presentableContacts(localContacts)
        }

        /// Keeps only entries worth listing — one with a real name or a phone
        /// number. Drops rows that are just a bare placeholder with nothing to
        /// show (e.g. an unresolved participant with neither).
        private static func presentableContacts(_ users: [User]) -> [User] {
            users.filter { user in
                let name = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasRealName =
                    !name.isEmpty
                    && name != User.serverPlaceholderDisplayName
                    && name != user.id
                    && UUID(uuidString: name) == nil
                let hasPhone = !user.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                return hasRealName || hasPhone
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
