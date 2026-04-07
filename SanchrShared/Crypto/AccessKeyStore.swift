import Foundation

public protocol AccessKeyStoreProtocol: AnyObject, Sendable {
    func store(mediaId: String, accessKey: Data, conversationId: String) async throws
    func retrieve(mediaId: String) async throws -> Data?
    func purgeExpired() async throws -> Int
    func deleteAll() async throws
}

public final class AccessKeyStore: AccessKeyStoreProtocol, @unchecked Sendable {
    public static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    private let localDatabase: LocalDatabaseProtocol
    private let ttl: TimeInterval

    public init(localDatabase: LocalDatabaseProtocol, ttl: TimeInterval = AccessKeyStore.defaultTTL) {
        self.localDatabase = localDatabase
        self.ttl = ttl
    }

    public func store(mediaId: String, accessKey: Data, conversationId: String) async throws {
        let entry = AccessKeyEntry(
            mediaId: mediaId, accessKey: accessKey,
            conversationId: conversationId, createdAt: Date())
        try await localDatabase.saveAccessKeyEntry(entry)
    }

    public func retrieve(mediaId: String) async throws -> Data? {
        guard let entry = try await localDatabase.fetchAccessKeyEntry(mediaId: mediaId) else {
            return nil
        }
        let age = Date().timeIntervalSince(entry.createdAt)
        if age > ttl {
            try await localDatabase.deleteAccessKeyEntry(mediaId: mediaId)
            return nil
        }
        return entry.accessKey
    }

    public func purgeExpired() async throws -> Int {
        let cutoff = Date().addingTimeInterval(-ttl)
        return try await localDatabase.purgeAccessKeyEntries(olderThan: cutoff)
    }

    public func deleteAll() async throws {
        try await localDatabase.deleteAllAccessKeyEntries()
    }
}
