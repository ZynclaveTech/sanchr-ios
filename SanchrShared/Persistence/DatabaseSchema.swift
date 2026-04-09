import Foundation
import GRDB

// MARK: - Database Migration Manager

/// Defines all database migrations. Each migration is idempotent and versioned.
/// Add new migrations at the end — never modify existing ones.
public enum DatabaseSchema {

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            // ── Users / Contacts ──────────────────────────────────────
            try db.create(table: "user") { t in
                t.primaryKey("id", .text).notNull()
                t.column("phoneNumber", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("avatarURL", .text)
                t.column("bio", .text)
                t.column("isVerified", .boolean).notNull().defaults(to: false)
                t.column("lastSeen", .datetime)
                t.column("identityKeyFingerprint", .text)
                t.column("status", .text).notNull().defaults(to: "offline")
                t.column("isLocalUser", .boolean).notNull().defaults(to: false)
            }

            // ── Conversations ─────────────────────────────────────────
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text).notNull()
                t.column("type", .text).notNull().defaults(to: "oneToOne")
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isMuted", .boolean).notNull().defaults(to: false)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("disappearingMessagesDuration", .double)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // Denormalized last message fields for fast list queries
                t.column("lastMessageId", .text)
                t.column("lastMessageContent", .text) // JSON-encoded MessageContent
                t.column("lastMessageTimestamp", .datetime)
                t.column("lastMessageSenderId", .text)
                t.column("lastMessageStatus", .text)
            }

            // ── Conversation Participants (join table) ────────────────
            try db.create(table: "conversationParticipant") { t in
                t.column("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                t.primaryKey(["conversationId", "userId"])
            }

            // ── Messages ──────────────────────────────────────────────
            try db.create(table: "message") { t in
                t.primaryKey("id", .text).notNull()
                t.column("conversationId", .text).notNull()
                    .indexed()
                    .references("conversation", onDelete: .cascade)
                t.column("senderId", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("contentJSON", .text).notNull() // JSON-encoded MessageContent
                t.column("status", .text).notNull().defaults(to: "sending")
                t.column("isOutgoing", .boolean).notNull()
                t.column("replyToMessageId", .text)
                t.column("expiresAt", .datetime)
            }

            // Composite index for conversation message listing (newest first)
            try db.create(
                index: "idx_message_conversation_timestamp",
                on: "message",
                columns: ["conversationId", "timestamp"]
            )

            // Index for expired message cleanup
            try db.create(
                index: "idx_message_expiresAt",
                on: "message",
                columns: ["expiresAt"],
                condition: Column("expiresAt") != nil
            )

            // ── Vault Items ───────────────────────────────────────────
            try db.create(table: "vaultItem") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("encryptionKey", .blob).notNull()
                t.column("encryptionIV", .blob).notNull()
                t.column("thumbnailData", .blob)
                t.column("encryptedThumbnailURL", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isCachedLocally", .boolean).notNull().defaults(to: false)
                t.column("remoteURL", .text)
                t.column("localURL", .text)
            }

            try db.create(
                index: "idx_vaultItem_type_createdAt",
                on: "vaultItem",
                columns: ["type", "createdAt"]
            )
        }

        migrator.registerMigration("v2_delivery_ack_queue") { db in
            try db.create(table: "pendingMessageAck", ifNotExists: true) { t in
                t.column("conversationId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["conversationId", "messageId"])
            }

            try db.create(
                index: "idx_pendingMessageAck_createdAt",
                on: "pendingMessageAck",
                columns: ["createdAt"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v3_access_key_entries") { db in
            try db.create(table: "accessKeyEntry", ifNotExists: true) { t in
                t.primaryKey("mediaId", .text).notNull()
                t.column("accessKey", .blob).notNull()
                t.column("conversationId", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(
                index: "idx_accessKeyEntry_createdAt",
                on: "accessKeyEntry",
                columns: ["createdAt"],
                ifNotExists: true
            )

            try db.create(
                index: "idx_accessKeyEntry_conversationId",
                on: "accessKeyEntry",
                columns: ["conversationId"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v4_chat_appearance_overrides") { db in
            try db.create(table: "chatAppearanceOverride", ifNotExists: true) { t in
                t.primaryKey("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("wallpaperId", .text)
                t.column("appearanceMode", .text)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v5_chat_vault_policy") { db in
            try db.create(table: "chatVaultPolicy", ifNotExists: true) { t in
                t.primaryKey("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("autoVaultIncoming", .boolean).notNull().defaults(to: false)
                t.column("viewOnceOutgoing", .boolean).notNull().defaults(to: false)
                t.column("screenshotProtection", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v6_vault_e2ee_access_key_extensions") { db in
            // Add kind and lastAccessedAt columns to accessKeyEntry. Existing
            // rows (from v3) get defaults: kind='messageMedia' (only producer
            // before this migration was the message-media D2 path), and
            // lastAccessedAt=createdAt (no prior access-tracking signal).
            try db.alter(table: "accessKeyEntry") { t in
                t.add(column: "kind", .text)
                    .notNull()
                    .defaults(to: "messageMedia")
                t.add(column: "lastAccessedAt", .datetime)
            }

            // Backfill lastAccessedAt. We can't use a .defaults(to: Column("createdAt"))
            // pattern in GRDB's AlterTable DSL, so we run an explicit UPDATE.
            try db.execute(sql: """
                UPDATE accessKeyEntry
                SET lastAccessedAt = createdAt
                WHERE lastAccessedAt IS NULL
                """)

            // Supporting index for the sliding-TTL purge query.
            try db.create(
                index: "idx_accessKeyEntry_lastAccessedAt",
                on: "accessKeyEntry",
                columns: ["lastAccessedAt"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v7_vault_items_forward_secure") { db in
            // Drop the plaintext-key columns from vaultItem and add the
            // forward-secure shape:
            // - mediaId: TEXT, references the media_objects row
            // - status: TEXT ('live' or 'sealed'), defaults to 'live'
            //
            // iOS 17+ ships SQLite 3.35+ which supports ALTER TABLE DROP
            // COLUMN natively, so the raw-SQL form works on all deployment
            // targets for this project.
            try db.execute(sql: "ALTER TABLE vaultItem DROP COLUMN encryptionKey")
            try db.execute(sql: "ALTER TABLE vaultItem DROP COLUMN encryptionIV")
            try db.execute(sql: "ALTER TABLE vaultItem ADD COLUMN mediaId TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE vaultItem ADD COLUMN status TEXT NOT NULL DEFAULT 'live'")

            // Index on (status, createdAt) so the UI list query that filters
            // out sealed items uses an index.
            try db.create(
                index: "idx_vaultItem_status_createdAt",
                on: "vaultItem",
                columns: ["status", "createdAt"],
                ifNotExists: true
            )
        }

        return migrator
    }
}
