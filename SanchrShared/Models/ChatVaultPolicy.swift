import Foundation

/// Per-chat vault policy. All three flags default to off; flipping a
/// toggle in the per-chat Vault Media UI persists a row in the
/// `chatVaultPolicy` SQLCipher table. There is no global merge — every
/// chat starts at defaults and only diverges when the user touches
/// the toggles for that specific chat.
public struct ChatVaultPolicy: Equatable, Sendable {
    public let conversationId: String
    public let autoVaultIncoming: Bool
    public let viewOnceOutgoing: Bool
    public let screenshotProtection: Bool

    public init(
        conversationId: String,
        autoVaultIncoming: Bool,
        viewOnceOutgoing: Bool,
        screenshotProtection: Bool
    ) {
        self.conversationId = conversationId
        self.autoVaultIncoming = autoVaultIncoming
        self.viewOnceOutgoing = viewOnceOutgoing
        self.screenshotProtection = screenshotProtection
    }

    /// All-off default for chats with no persisted row yet.
    public static func defaults(for conversationId: String) -> ChatVaultPolicy {
        ChatVaultPolicy(
            conversationId: conversationId,
            autoVaultIncoming: false,
            viewOnceOutgoing: false,
            screenshotProtection: false
        )
    }
}
