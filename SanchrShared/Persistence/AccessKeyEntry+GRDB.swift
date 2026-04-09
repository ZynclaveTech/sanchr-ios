import Foundation
import GRDB

/// GRDB Record for AccessKeyEntry persistence.
struct AccessKeyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "accessKeyEntry"

    let mediaId: String           // Primary key
    let accessKey: Data
    let conversationId: String
    let kind: String              // Stored as String for future forward-compat
    let createdAt: Date
    let lastAccessedAt: Date

    enum Columns {
        static let mediaId = Column(CodingKeys.mediaId)
        static let accessKey = Column(CodingKeys.accessKey)
        static let conversationId = Column(CodingKeys.conversationId)
        static let kind = Column(CodingKeys.kind)
        static let createdAt = Column(CodingKeys.createdAt)
        static let lastAccessedAt = Column(CodingKeys.lastAccessedAt)
    }
}

extension AccessKeyRecord {
    init(entry: AccessKeyEntry) {
        self.mediaId = entry.mediaId
        self.accessKey = entry.accessKey
        self.conversationId = entry.conversationId
        self.kind = entry.kind.rawValue
        self.createdAt = entry.createdAt
        self.lastAccessedAt = entry.lastAccessedAt
    }

    func toEntry() -> AccessKeyEntry {
        AccessKeyEntry(
            mediaId: mediaId,
            accessKey: accessKey,
            conversationId: conversationId,
            kind: AccessKeyEntry.Kind(rawValue: kind) ?? .messageMedia,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt
        )
    }
}
