import Foundation
import SanchrShared

/// Main-app `VaultPolicyResolving` adapter. Hops to @MainActor and
/// reads from the shared `ChatVaultPolicyService` instance held by
/// the dependency container.
final class MainAppVaultPolicyResolver: VaultPolicyResolving, @unchecked Sendable {
    private let service: ChatVaultPolicyService

    init(service: ChatVaultPolicyService) {
        self.service = service
    }

    func policy(for conversationId: String) async -> ChatVaultPolicy {
        await MainActor.run {
            service.effectivePolicy(for: conversationId)
        }
    }
}
