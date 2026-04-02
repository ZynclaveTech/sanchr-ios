import Foundation

/// Data source for contact-related gRPC service calls.
final class ContactDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // TODO: Implement when proto-generated stubs are available
    //
    // func fetchContacts() async throws -> [User] { ... }
    // func syncContacts(hashedNumbers: [String]) async throws -> [User] { ... }
    // func blockUser(userId: String) async throws { ... }
    // func unblockUser(userId: String) async throws { ... }
}
