import CryptoKit
import Foundation
import SanchrShared

/// Protocol defining contact operations.
protocol ContactRepositoryProtocol: AnyObject, Sendable {
    /// Fetches the user's contact list from the server.
    func fetchContacts() async throws -> [User]

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
