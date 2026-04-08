import Foundation
import SanchrShared

/// Share-extension `VaultPolicyResolving` stub. Always returns
/// defaults — the share extension does not support per-chat
/// policy customization yet (deferred to a future spec; see
/// docs/superpowers/specs/2026-04-08-vault-media-policy-design.md
/// §9 Out of scope).
struct NoopVaultPolicyResolver: VaultPolicyResolving {
    func policy(for conversationId: String) async -> ChatVaultPolicy {
        .defaults(for: conversationId)
    }
}
