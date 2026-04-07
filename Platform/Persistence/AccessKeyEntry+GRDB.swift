import Foundation
import GRDB
import SanchrShared

/// GRDB Record for AccessKeyEntry persistence.
struct AccessKeyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "accessKeyEntry"

    let mediaId: String
    let accessKey: Data
    let conversationId: String
    let createdAt: Date

    enum Columns {
        static let mediaId = Column(CodingKeys.mediaId)
        static let accessKey = Column(CodingKeys.accessKey)
        static let conversationId = Column(CodingKeys.conversationId)
        static let createdAt = Column(CodingKeys.createdAt)
    }
}

extension AccessKeyRecord {
    init(entry: AccessKeyEntry) {
        self.mediaId = entry.mediaId
        self.accessKey = entry.accessKey
        self.conversationId = entry.conversationId
        self.createdAt = entry.createdAt
    }

    func toEntry() -> AccessKeyEntry {
        AccessKeyEntry(
            mediaId: mediaId,
            accessKey: accessKey,
            conversationId: conversationId,
            createdAt: createdAt
        )
    }
}
