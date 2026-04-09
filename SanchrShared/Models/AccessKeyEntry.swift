import Foundation

/// Media access key record persisted to the local encrypted store.
public struct AccessKeyEntry: Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Existing D2 message-media access keys.
        case messageMedia
        /// Vault item created from an incoming message (reserved for
        /// forward-compat; no producer in v1 of this rewrite).
        case vaultAutoVaulted
        /// Vault item created by direct manual upload.
        case vaultManual
    }

    /// Opaque primary key. For `messageMedia` this is a `media_id`. For both
    /// vault kinds this is a `vault_item_id`. The two ID spaces are disjoint
    /// (both UUIDv4) so a single column serves all three kinds without a join.
    ///
    /// The name `mediaId` is a historical artifact; a future cleanup can
    /// rename it to `accessKeyId` once the vault rewrite is stable.
    public let mediaId: String

    public let accessKey: Data

    /// Empty string for both vault kinds (no conversation context).
    public let conversationId: String

    public let kind: Kind

    public let createdAt: Date

    /// Bumped by the store on every successful decrypt via `touch()` or
    /// `getAndTouch()`. In-memory copies are immutable — to observe an
    /// updated value, re-fetch via `AccessKeyStoreProtocol.retrieveEntry`.
    /// Effective expiry is `GREATEST(createdAt, lastAccessedAt) + 30 days`.
    public let lastAccessedAt: Date

    public init(
        mediaId: String,
        accessKey: Data,
        conversationId: String,
        kind: Kind,
        createdAt: Date,
        lastAccessedAt: Date
    ) {
        self.mediaId = mediaId
        self.accessKey = accessKey
        self.conversationId = conversationId
        self.kind = kind
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}
