import Foundation

// MARK: - vync.contacts gRPC Client
// Generated from Proto/contacts.proto — DO NOT EDIT

/// Client protocol for the ContactService gRPC service.
protocol Vync_Contacts_ContactServiceClientProtocol: Sendable {
    /// Syncs device contacts (as hashed phone numbers) to find existing users.
    func syncContacts(_ request: Vync_Contacts_SyncContactsRequest) async throws -> Vync_Contacts_SyncContactsResponse

    /// Fetches the user's server-side contact list.
    func getContacts(_ request: Vync_Contacts_GetContactsRequest) async throws -> Vync_Contacts_GetContactsResponse

    /// Blocks a contact, preventing message delivery.
    func blockContact(_ request: Vync_Contacts_BlockContactRequest) async throws -> Vync_Contacts_BlockContactResponse

    /// Unblocks a previously blocked contact.
    func unblockContact(_ request: Vync_Contacts_UnblockContactRequest) async throws -> Vync_Contacts_UnblockContactResponse

    /// Retrieves the list of blocked user IDs.
    func getBlockedList(_ request: Vync_Contacts_GetBlockedListRequest) async throws -> Vync_Contacts_GetBlockedListResponse
}

/// Concrete gRPC client for ContactService.
final class Vync_Contacts_ContactServiceClient: Vync_Contacts_ContactServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func syncContacts(_ request: Vync_Contacts_SyncContactsRequest) async throws -> Vync_Contacts_SyncContactsResponse {
        SanchrLogger.network.info("gRPC: ContactService/SyncContacts")
        throw AppError.serverUnreachable
    }

    func getContacts(_ request: Vync_Contacts_GetContactsRequest) async throws -> Vync_Contacts_GetContactsResponse {
        SanchrLogger.network.info("gRPC: ContactService/GetContacts")
        throw AppError.serverUnreachable
    }

    func blockContact(_ request: Vync_Contacts_BlockContactRequest) async throws -> Vync_Contacts_BlockContactResponse {
        SanchrLogger.network.info("gRPC: ContactService/BlockContact")
        throw AppError.serverUnreachable
    }

    func unblockContact(_ request: Vync_Contacts_UnblockContactRequest) async throws -> Vync_Contacts_UnblockContactResponse {
        SanchrLogger.network.info("gRPC: ContactService/UnblockContact")
        throw AppError.serverUnreachable
    }

    func getBlockedList(_ request: Vync_Contacts_GetBlockedListRequest) async throws -> Vync_Contacts_GetBlockedListResponse {
        SanchrLogger.network.info("gRPC: ContactService/GetBlockedList")
        throw AppError.serverUnreachable
    }
}
