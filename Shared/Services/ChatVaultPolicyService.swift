import Foundation
import SanchrShared

@Observable
@MainActor
final class ChatVaultPolicyService {
    /// Bumped on every setPolicy call. SwiftUI views that read this
    /// inside body register an unambiguous observation dependency.
    var changeVersion: UInt64 = 0

    private var cache: [String: ChatVaultPolicy] = [:]
    private var loadedConversationIds: Set<String> = []
    private let localDatabase: LocalDatabaseProtocol

    /// Lock-protected mirror exposed to the background realtime
    /// decode path. Updated by `setPolicy` and `loadPolicy` (both
    /// @MainActor) and read by `MessageRepositoryImpl.decodeMessage`
    /// without an actor hop.
    let mirror = ChatVaultPolicyMirror()

    init(localDatabase: LocalDatabaseProtocol) {
        self.localDatabase = localDatabase
    }

    func effectivePolicy(for conversationId: String) -> ChatVaultPolicy {
        cache[conversationId] ?? .defaults(for: conversationId)
    }

    func loadPolicy(conversationId: String) async {
        guard !loadedConversationIds.contains(conversationId) else { return }
        loadedConversationIds.insert(conversationId)
        if let row = try? await localDatabase.fetchVaultPolicy(conversationId: conversationId) {
            cache[conversationId] = row
            mirror.write(row)
        }
    }

    func setPolicy(_ policy: ChatVaultPolicy) async {
        do {
            try await localDatabase.setVaultPolicy(policy)
        } catch {
            SanchrLogger.chat.error(
                "ChatVaultPolicy.setPolicy DB write failed: \(error.localizedDescription)"
            )
        }
        cache[policy.conversationId] = policy
        mirror.write(policy)
        loadedConversationIds.insert(policy.conversationId)
        changeVersion &+= 1
        NotificationCenter.default.post(
            name: .chatVaultPolicyDidChange,
            object: self,
            userInfo: ["conversationId": policy.conversationId]
        )
    }
}

extension Notification.Name {
    static let chatVaultPolicyDidChange = Notification.Name("sanchr.chatVaultPolicyDidChange")
}

/// Lock-protected mirror of `ChatVaultPolicyService.cache` so the
/// background message-handling path (`MessageRepositoryImpl.decodeMessage`)
/// can read per-chat policy synchronously without awaiting the
/// @MainActor resolver. Same precedent as `MediaDownloadManager`'s
/// `inFlight` Set, which is also a thread-safe accessor across actor
/// boundaries.
final class ChatVaultPolicyMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ChatVaultPolicy] = [:]

    func policy(for conversationId: String) -> ChatVaultPolicy? {
        lock.lock(); defer { lock.unlock() }
        return storage[conversationId]
    }

    func write(_ policy: ChatVaultPolicy) {
        lock.lock(); defer { lock.unlock() }
        storage[policy.conversationId] = policy
    }

    func remove(conversationId: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: conversationId)
    }
}
