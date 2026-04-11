import CryptoKit
import Foundation
import SanchrShared

/// Data source for contact-related gRPC service calls.
/// Translates between domain models and Sanchr_Contacts protobuf messages.
final class ContactDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol

    private var contactClient: Sanchr_Contacts_ContactServiceAsyncClientProtocol {
        grpcClient.contactService
    }

    init(grpcClient: GRPCClientProtocol, localDatabase: LocalDatabaseProtocol) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
    }

    // MARK: - Sync Contacts

    /// Sends SHA-256 hashed phone numbers to the server and returns matched Sanchr users.
    func syncContacts(phoneHashes: [Data]) async throws -> [User] {
        var request = Sanchr_Contacts_SyncContactsRequest()
        request.phoneHashes = phoneHashes

        SanchrLogger.network.info(
            "ContactDataSource: syncContacts with \(phoneHashes.count) hashes")
        let response = try await contactClient.syncContacts(request)

        let users = response.matches.map(Self.mapMatchedContactToUser)

        // Cache locally
        for user in users {
            try? await localDatabase.saveContact(user)
        }

        return users
    }

    // MARK: - Get Contacts

    /// Fetches the full contact list from the server and updates local cache.
    func getContacts() async throws -> [User] {
        let request = Sanchr_Contacts_GetContactsRequest()

        SanchrLogger.network.info("ContactDataSource: getContacts")
        let response = try await contactClient.getContacts(request)

        let users = response.contacts.map(Self.mapContactToUser)

        // Refresh local cache
        for user in users {
            try? await localDatabase.saveContact(user)
        }

        return users
    }

    // MARK: - Block / Unblock

    /// Blocks a contact by user ID.
    func blockContact(userId: String) async throws {
        var request = Sanchr_Contacts_BlockContactRequest()
        request.contactUserID = userId

        SanchrLogger.network.info("ContactDataSource: blockContact \(userId.prefix(8))...")
        _ = try await contactClient.blockContact(request)
    }

    /// Unblocks a previously blocked contact.
    func unblockContact(userId: String) async throws {
        var request = Sanchr_Contacts_UnblockContactRequest()
        request.contactUserID = userId

        SanchrLogger.network.info("ContactDataSource: unblockContact \(userId.prefix(8))...")
        _ = try await contactClient.unblockContact(request)
    }

    // MARK: - Blocked List

    /// Fetches the list of blocked user IDs from the server.
    func getBlockedList() async throws -> [String] {
        let request = Sanchr_Contacts_GetBlockedListRequest()

        SanchrLogger.network.info("ContactDataSource: getBlockedList")
        let response = try await contactClient.getBlockedList(request)

        return response.blockedUserIds
    }

    // MARK: - Hashing

    /// Hashes a phone number using SHA-256 for privacy-preserving contact discovery.
    static func hashPhoneNumber(_ phoneNumber: String) -> Data {
        let normalized = normalizePhoneNumber(phoneNumber)
        let data = Data(normalized.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    /// Normalize a phone number for comparison — strips whitespace,
    /// dashes, and parentheses. Keeps the leading `+` and digits so
    /// `"+91 98765 43210"` matches `"+919876543210"`. MUST be used
    /// everywhere a phone needs to match another phone (contact lookup,
    /// bubble viewer resolution) so there is exactly one definition of
    /// "same phone" in the app.
    static func normalizePhoneNumber(_ phoneNumber: String) -> String {
        phoneNumber
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    // MARK: - Mapping

    /// Maps a gRPC MatchedContact to the domain User model.
    static func mapMatchedContactToUser(_ matched: Sanchr_Contacts_MatchedContact) -> User {
        User(
            id: matched.userID,
            phoneNumber: matched.phoneNumber,
            displayName: matched.displayName,
            avatarURL: matched.avatarURL.isEmpty ? nil : URL(string: matched.avatarURL),
            bio: matched.statusText.isEmpty ? nil : matched.statusText,
            isVerified: true,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline
        )
    }

    /// Maps a gRPC Contact to the domain User model.
    static func mapContactToUser(_ contact: Sanchr_Contacts_Contact) -> User {
        User(
            id: contact.userID,
            phoneNumber: contact.phoneNumber,
            displayName: contact.displayName,
            avatarURL: contact.avatarURL.isEmpty ? nil : URL(string: contact.avatarURL),
            bio: contact.statusText.isEmpty ? nil : contact.statusText,
            isVerified: true,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline
        )
    }
}
