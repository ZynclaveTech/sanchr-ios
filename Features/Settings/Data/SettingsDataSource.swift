import Foundation

/// Data source for settings-related gRPC service calls.
final class SettingsDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // TODO: Implement when proto-generated stubs are available
    //
    // func updatePrivacySettings(request: Settings_PrivacyRequest) async throws { ... }
    // func updateNotificationSettings(request: Settings_NotificationRequest) async throws { ... }
    // func deleteAccount() async throws { ... }
}
