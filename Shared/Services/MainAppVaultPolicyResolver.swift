import Foundation
import SanchrShared

/// Main-app `VaultPolicyResolving` adapter. Hops to @MainActor and
/// reads from the shared `ChatVaultPolicyService` instance.
///
/// Holds a `@MainActor`-isolated factory closure rather than the
/// service directly so it can be constructed from the nonisolated
/// `messageSender` lazy var on `DependencyContainer` without
/// crossing actor boundaries at init time. The closure runs inside
/// the `MainActor.run` hop in `policy(for:)`.
final class MainAppVaultPolicyResolver: VaultPolicyResolving, @unchecked Sendable {
    private let serviceProvider: @MainActor @Sendable () -> ChatVaultPolicyService

    init(serviceProvider: @escaping @MainActor @Sendable () -> ChatVaultPolicyService) {
        self.serviceProvider = serviceProvider
    }

    func policy(for conversationId: String) async -> ChatVaultPolicy {
        await MainActor.run {
            serviceProvider().effectivePolicy(for: conversationId)
        }
    }
}
