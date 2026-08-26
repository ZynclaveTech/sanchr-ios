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
    private let profileKeyStore: ProfileKeyStoreProtocol
    private let profileCrypto: ProfileCryptoProtocol

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        profileKeyStore: ProfileKeyStoreProtocol,
        profileCrypto: ProfileCryptoProtocol
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.profileKeyStore = profileKeyStore
        self.profileCrypto = profileCrypto
    }

    // MARK: - Private helpers

    /// Attempts to decrypt `ciphertext` with `profileKey` for `field`.
    /// Returns `nil` on empty input or any decryption failure — callers decide the fallback.
    private func tryDecrypt(
        _ ciphertext: Data,
        profileKey: Data,
        field: ProfileField
    ) -> String? {
        guard !ciphertext.isEmpty else { return nil }
        return try? profileCrypto.decryptField(ciphertext, profileKey: profileKey, field: field)
    }

    func fetchContacts() async throws -> [User] {
        SanchrLogger.sync.info("Fetching contacts from server")

        let request = Sanchr_Contacts_GetContactsRequest()
        let response = try await grpcClient.contactService.getContacts(request)

        let users = response.contacts.map { contact -> User in
            var displayName = contact.displayName
            var bio: String? = contact.statusText.isEmpty ? nil : contact.statusText
            var avatarURL: URL? = URL(string: contact.avatarURL)

            // Only a Profile Key delivered over the Signal session is trusted. A key
            // offered by the server is ignored: the server also holds the ciphertext,
            // so accepting its key would let it choose what we decrypt and would make
            // the encryption meaningless.
            //
            // Until the key arrives we deliberately do not fall back to the
            // server-supplied plaintext — displaying it would leak exactly what the
            // encryption exists to hide. The phone number stands in instead.
            if let localKey = try? profileKeyStore.contactProfileKey(forUserId: contact.userID),
                !localKey.isEmpty
            {
                if let decrypted = tryDecrypt(contact.encryptedDisplayName,
                                              profileKey: localKey, field: .displayName) {
                    displayName = decrypted
                }
                if let decrypted = tryDecrypt(contact.encryptedBio,
                                              profileKey: localKey, field: .bio) {
                    bio = decrypted
                }
                if let decrypted = tryDecrypt(contact.encryptedAvatarURL,
                                              profileKey: localKey, field: .avatarURL) {
                    avatarURL = URL(string: decrypted)
                }
            } else {
                displayName = contact.phoneNumber.isEmpty ? "Unknown contact" : contact.phoneNumber
                bio = nil
                avatarURL = nil
            }

            return User(
                id: contact.userID,
                phoneNumber: contact.phoneNumber,
                displayName: displayName,
                avatarURL: avatarURL,
                bio: bio,
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

        var request = Sanchr_Contacts_SyncContactsRequest()
        request.phoneHashes = hashes

        let response = try await grpcClient.contactService.syncContacts(request)

        let matchedUsers = response.matches.map { match -> User in
            var displayName = match.displayName
            var bio: String? = match.statusText.isEmpty ? nil : match.statusText
            var avatarURL: URL? = URL(string: match.avatarURL)

            if !match.profileKey.isEmpty {
                try? profileKeyStore.saveContactProfileKey(match.profileKey, forUserId: match.userID)

                if let decrypted = tryDecrypt(match.encryptedDisplayName,
                                              profileKey: match.profileKey, field: .displayName) {
                    displayName = decrypted
                }
                if let decrypted = tryDecrypt(match.encryptedBio,
                                              profileKey: match.profileKey, field: .bio) {
                    bio = decrypted
                }
                if let decrypted = tryDecrypt(match.encryptedAvatarURL,
                                              profileKey: match.profileKey, field: .avatarURL) {
                    avatarURL = URL(string: decrypted)
                }
            }

            return User(
                id: match.userID,
                phoneNumber: match.phoneNumber,
                displayName: displayName,
                avatarURL: avatarURL,
                bio: bio,
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

        var request = Sanchr_Contacts_SyncContactsRequest()
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

        var request = Sanchr_Contacts_BlockContactRequest()
        request.contactUserID = userId

        _ = try await grpcClient.contactService.blockContact(request)
    }

    func unblockUser(userId: String) async throws {
        SanchrLogger.sync.info("Unblocking user \(userId.prefix(8))...")

        var request = Sanchr_Contacts_UnblockContactRequest()
        request.contactUserID = userId

        _ = try await grpcClient.contactService.unblockContact(request)
    }

    func fetchBlockedUsers() async throws -> [User] {
        SanchrLogger.sync.info("Fetching blocked users list")

        let request = Sanchr_Contacts_GetBlockedListRequest()
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

        var request = Sanchr_Settings_UpdateProfileRequest()
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
