import Foundation

/// Cross-isolation seam used by the actor-isolated `MessageSender`
/// to read per-chat vault policy without depending on the @MainActor
/// `ChatVaultPolicyService` directly. The main app provides an
/// adapter that hops to @MainActor; the share extension provides a
/// no-op stub because the share extension does not (yet) support
/// per-chat policy customization.
public protocol VaultPolicyResolving: Sendable {
    func policy(for conversationId: String) async -> ChatVaultPolicy
}
