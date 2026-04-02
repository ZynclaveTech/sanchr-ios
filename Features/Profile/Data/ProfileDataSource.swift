import Foundation

/// Data source for profile-related gRPC service calls.
final class ProfileDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // TODO: Implement when proto-generated stubs are available
    //
    // func getProfile() async throws -> User { ... }
    // func updateProfile(displayName: String?, bio: String?, avatarData: Data?) async throws -> User { ... }
    // func uploadAvatar(data: Data) async throws -> URL { ... }
}
