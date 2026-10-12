import Foundation
import SanchrShared

/// Deletes messages whose disappearing-message deadline has passed.
///
/// Expiry is enforced entirely on the device. The server stamps a TTL on the
/// non-sealed path and lets undelivered ciphertext lapse, but that only reaps
/// what was never delivered — once a message reaches a device it is the device's
/// job to remove it. Without this, a timer set in the UI changed nothing on
/// either end.
///
/// Runs on launch, on every foreground, and on a timer while the app is open, so
/// a conversation left on screen does not hold expired messages indefinitely.
/// `fetchMessages` also filters by deadline, so a message is never *shown* after
/// expiry even in the window before a sweep removes it.
actor DisappearingMessageSweeper {

    private let localDatabase: LocalDatabaseProtocol
    private let mediaDownloadManager: MediaDownloadManager
    private let interval: TimeInterval
    /// Takes down the delivered notifications for a conversation. A
    /// notification can carry a preview of the message that has just expired.
    private let clearNotifications: @Sendable (_ conversationId: String) -> Void
    private var tickTask: Task<Void, Never>?

    init(
        localDatabase: LocalDatabaseProtocol,
        mediaDownloadManager: MediaDownloadManager,
        interval: TimeInterval = 30,
        clearNotifications: @escaping @Sendable (_ conversationId: String) -> Void = {
            SanchrNotificationService.clearNotifications(for: $0)
        }
    ) {
        self.localDatabase = localDatabase
        self.mediaDownloadManager = mediaDownloadManager
        self.interval = interval
        self.clearNotifications = clearNotifications
    }

    deinit {
        tickTask?.cancel()
    }

    /// Removes everything currently past its deadline. Returns how many rows went.
    ///
    /// Media files are wiped before the caller is told anything happened, because
    /// a decrypted attachment left on disk after its message is gone is the same
    /// disclosure the timer existed to prevent.
    @discardableResult
    func sweep() async -> Int {
        let expiredIds: [String]
        // Which chats they were in comes back with the purge itself: asked
        // separately, a message expiring in between would go unreported.
        let notified: [String]
        do {
            let purge = try await localDatabase.purgeExpiredMessagesReportingConversations()
            expiredIds = purge.messageIds
            notified = purge.conversationIdsWithIncoming
        } catch {
            SanchrLogger.chat.error(
                "Disappearing sweep failed: \(error.localizedDescription)")
            return 0
        }

        guard !expiredIds.isEmpty else { return 0 }

        for id in expiredIds {
            await mediaDownloadManager.removeCachedFile(messageId: id)
        }
        for conversationId in notified {
            clearNotifications(conversationId)
        }

        SanchrLogger.chat.info("Disappearing sweep removed \(expiredIds.count) message(s)")
        await MainActor.run {
            NotificationCenter.default.post(name: .sanchrMessagesDidExpire, object: nil)
        }
        return expiredIds.count
    }

    /// Starts the periodic sweep. Idempotent — calling it again keeps one timer.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self, interval] in
            while !Task.isCancelled {
                await self?.sweep()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }
}

extension Notification.Name {
    /// Posted after a sweep removed at least one message, so open transcripts can
    /// drop the rows rather than displaying content the database no longer has.
    static let sanchrMessagesDidExpire = Notification.Name(
        "io.sanchr.chat.messagesDidExpire")
}
