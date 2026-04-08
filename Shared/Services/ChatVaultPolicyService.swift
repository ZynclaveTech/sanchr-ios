import Foundation
import SanchrShared

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
