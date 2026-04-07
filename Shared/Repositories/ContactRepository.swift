import CryptoKit
import Foundation
import SanchrShared

/// Protocol defining contact operations.
protocol ContactRepositoryProtocol: AnyObject, Sendable {
    /// Fetches the user's contact list from the server.
    func fetchContacts() async throws -> [User]

    /// Syncs device contacts with the server to discover Sanchr users.
    func syncDeviceContacts(phoneNumbers: [String]) async throws -> [User]

    /// Searches for a user by phone number.
    func searchUser(phoneNumber: String) async throws -> User?

    /// Blocks a user.
    func blockUser(userId: String) async throws

    /// Unblocks a user.
    func unblockUser(userId: String) async throws

    /// Fetches the list of blocked users.
    func fetchBlockedUsers() async throws -> [User]

    /// Updates the current user's profile.
    func updateProfile(displayName: String?, bio: String?, avatarData: Data?) async throws -> User
}

// MARK: - Implementation

final class ContactRepositoryImpl: ContactRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol

    init(grpcClient: GRPCClientProtocol, localDatabase: LocalDatabaseProtocol) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
    }

    func fetchContacts() async throws -> [User] {
        SanchrLogger.sync.info("Fetching contacts from server")

        let request = Vync_Contacts_GetContactsRequest()
        let response = try await grpcClient.contactService.getContacts(request)

        let users = response.contacts.map { contact in
            User(
                id: contact.userID,
                phoneNumber: contact.phoneNumber,
                displayName: contact.displayName,
                avatarURL: URL(string: contact.avatarURL),
                bio: contact.statusText.isEmpty ? nil : contact.statusText,
                isVerified: false,
                lastSeen: nil,
                identityKeyFingerprint: nil,
                status: .offline
            )
        }

        // Cache contacts locally
        for user in users {
            try? await localDatabase.saveContact(user)
        }

        return users
    }

    func syncDeviceContacts(phoneNumbers: [String]) async throws -> [User] {
        SanchrLogger.sync.info("Syncing \(phoneNumbers.count) device contacts")

        // Hash phone numbers with SHA256 before sending to server
        let hashes = phoneNumbers.map { phone -> Data in
            let normalized = phone.replacingOccurrences(of: "[^0-9+]", with: "", options: .regularExpression)
            return Data(SHA256.hash(data: Data(normalized.utf8)))
        }

        var request = Vync_Contacts_SyncContactsRequest()
        request.phoneHashes = hashes

        let response = try await grpcClient.contactService.syncContacts(request)

        let matchedUsers = response.matches.map { match in
            User(
                id: match.userID,
                phoneNumber: match.phoneNumber,
                displayName: match.displayName,
                avatarURL: URL(string: match.avatarURL),
                bio: match.statusText.isEmpty ? nil : match.statusText,
                isVerified: false,
                lastSeen: nil,
                identityKeyFingerprint: nil,
                status: .offline
            )
        }

        // Cache matched contacts locally
        for user in matchedUsers {
            try? await localDatabase.saveContact(user)
        }

        SanchrLogger.sync.info("Found \(matchedUsers.count) Sanchr users from device contacts")
        return matchedUsers
    }

    func searchUser(phoneNumber: String) async throws -> User? {
        SanchrLogger.sync.info("Searching for user by phone number")

        // Use syncContacts with a single number to find the user
        let normalized = phoneNumber.replacingOccurrences(of: "[^0-9+]", with: "", options: .regularExpression)
        let hash = Data(SHA256.hash(data: Data(normalized.utf8)))

        var request = Vync_Contacts_SyncContactsRequest()
        request.phoneHashes = [hash]

        let response = try await grpcClient.contactService.syncContacts(request)

        guard let match = response.matches.first else {
            return nil
        }

        return User(
            id: match.userID,
            phoneNumber: phoneNumber,
            displayName: match.displayName,
            avatarURL: URL(string: match.avatarURL),
            bio: match.statusText.isEmpty ? nil : match.statusText,
            isVerified: false,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline
        )
    }

    func blockUser(userId: String) async throws {
        SanchrLogger.sync.info("Blocking user \(userId.prefix(8))...")

        var request = Vync_Contacts_BlockContactRequest()
        request.contactUserID = userId

        _ = try await grpcClient.contactService.blockContact(request)
    }

    func unblockUser(userId: String) async throws {
        SanchrLogger.sync.info("Unblocking user \(userId.prefix(8))...")

        var request = Vync_Contacts_UnblockContactRequest()
        request.contactUserID = userId

        _ = try await grpcClient.contactService.unblockContact(request)
    }

    func fetchBlockedUsers() async throws -> [User] {
        SanchrLogger.sync.info("Fetching blocked users list")

        let request = Vync_Contacts_GetBlockedListRequest()
        let response = try await grpcClient.contactService.getBlockedList(request)

        // The response only has user IDs; create placeholder users.
        // A full implementation would fetch profiles for these IDs.
        return response.blockedUserIds.map { userId in
            User(
                id: userId,
                phoneNumber: "",
                displayName: "Blocked User",
                avatarURL: nil,
                bio: nil,
                isVerified: false,
                lastSeen: nil,
                identityKeyFingerprint: nil,
                status: .offline
            )
        }
    }

    func updateProfile(displayName: String?, bio: String?, avatarData: Data?) async throws -> User {
        SanchrLogger.sync.info("Updating user profile")

        var request = Vync_Settings_UpdateProfileRequest()
        if let displayName { request.displayName = displayName }
        if let bio { request.statusText = bio }
        // Avatar upload would require media service; set URL if avatar was uploaded separately
        // For now, avatarData is not directly supported by the proto -- would need media upload first.

        let response = try await grpcClient.settingsService.updateProfile(request)

        return User(
            id: response.id,
            phoneNumber: "",
            displayName: response.displayName,
            avatarURL: URL(string: response.avatarURL),
            bio: response.statusText.isEmpty ? nil : response.statusText,
            isVerified: false,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .online,
            isLocalUser: true
        )
    }
}
