import Foundation

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

// MARK: - Implementation Shell

final class ContactRepositoryImpl: ContactRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol

    init(grpcClient: GRPCClientProtocol, localDatabase: LocalDatabaseProtocol) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
    }

    func fetchContacts() async throws -> [User] {
        // TODO: Fetch from server, update local DB, return merged list
        return try await localDatabase.fetchContacts()
    }

    func syncDeviceContacts(phoneNumbers: [String]) async throws -> [User] {
        SanchrLogger.sync.info("Syncing \(phoneNumbers.count) device contacts")
        // TODO: Hash phone numbers, send to server, get matching Sanchr users
        return []
    }

    func searchUser(phoneNumber: String) async throws -> User? {
        // TODO: Call gRPC contact.SearchUser
        return nil
    }

    func blockUser(userId: String) async throws {
        // TODO: Call gRPC contact.BlockUser
    }

    func unblockUser(userId: String) async throws {
        // TODO: Call gRPC contact.UnblockUser
    }

    func fetchBlockedUsers() async throws -> [User] {
        // TODO: Call gRPC contact.GetBlockedUsers
        return []
    }

    func updateProfile(displayName: String?, bio: String?, avatarData: Data?) async throws -> User {
        // TODO: Call gRPC profile.UpdateProfile
        throw AppError.serverUnreachable
    }
}
