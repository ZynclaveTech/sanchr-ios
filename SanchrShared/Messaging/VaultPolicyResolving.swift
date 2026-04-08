import Foundation

/// Cross-isolation seam used by the actor-isolated `MessageSender`
/// to read per-chat vault policy without depending on the @MainActor
/// `ChatVaultPolicyService` directly. The main app provides an
/// adapter that hops to @MainActor; the share extension uses
/// `NoopVaultPolicyResolver` because the share extension does not
/// (yet) support per-chat policy customization.
public protocol VaultPolicyResolving: Sendable {
    func policy(for conversationId: String) async -> ChatVaultPolicy
}

/// Always returns defaults — used by the share extension which
/// can't reach the main-app `ChatVaultPolicyService`. Per-chat
/// view-once respect from the share extension is deferred to a
/// future spec; see
/// docs/superpowers/specs/2026-04-08-vault-media-policy-design.md
/// §9 Out of scope.
public struct NoopVaultPolicyResolver: VaultPolicyResolving {
    public init() {}
    public func policy(for conversationId: String) async -> ChatVaultPolicy {
        .defaults(for: conversationId)
    }
}
