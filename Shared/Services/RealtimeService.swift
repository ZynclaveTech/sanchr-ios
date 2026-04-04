import Foundation

extension Notification.Name {
    static let sanchrConversationStateDidChange = Notification.Name("io.sanchr.realtime.conversationStateDidChange")
    static let sanchrRealtimeMessageReceived = Notification.Name("io.sanchr.realtime.messageReceived")
    static let sanchrRealtimeTypingChanged = Notification.Name("io.sanchr.realtime.typingChanged")
    static let sanchrRealtimeReceiptUpdated = Notification.Name("io.sanchr.realtime.receiptUpdated")
    static let sanchrRealtimePresenceUpdated = Notification.Name("io.sanchr.realtime.presenceUpdated")
}

enum RealtimeNotificationKey {
    static let conversationId = "conversationId"
    static let message = "message"
    static let typing = "typing"
    static let receipt = "receipt"
    static let presence = "presence"
}

@Observable
final class RealtimeService: @unchecked Sendable {
    private let messageRepository: MessageRepositoryProtocol
    private let signalKeyManager: KeyManagerProtocol
    private let sessionService: SessionService
    private let callManager: CallEventRouting

    private var streamTask: Task<Void, Never>?
    private(set) var isRunning = false

    init(
        messageRepository: MessageRepositoryProtocol,
        signalKeyManager: KeyManagerProtocol,
        sessionService: SessionService,
        callManager: CallEventRouting
    ) {
        self.messageRepository = messageRepository
        self.signalKeyManager = signalKeyManager
        self.sessionService = sessionService
        self.callManager = callManager
    }

    func start() {
        guard streamTask == nil, sessionService.isAuthenticated else { return }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                isRunning = true
                _ = try await messageRepository.flushPendingAcks()
                let stream = try await messageRepository.openMessageStream()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await handle(event)
                }
            } catch {
                SanchrLogger.chat.error("Realtime stream failed: \(error.localizedDescription)")
            }

            isRunning = false
            streamTask = nil
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isRunning = false
    }

    @discardableResult
    func syncNow() async -> Int {
        guard sessionService.isAuthenticated else { return 0 }

        do {
            let result = try await messageRepository.syncPendingMessages(
                sinceTimestamp: sessionService.lastMessageSyncTimestamp
            )
            _ = try await messageRepository.flushPendingAcks()
            if result.latestTimestamp > sessionService.lastMessageSyncTimestamp {
                sessionService.setLastMessageSyncTimestamp(result.latestTimestamp)
            }
            if result.appliedCount > 0 {
                NotificationCenter.default.post(name: .sanchrConversationStateDidChange, object: nil)
            }
            return result.appliedCount
        } catch {
            SanchrLogger.sync.error("Realtime sync failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func handle(_ event: RealtimeEvent) async {
        switch event {
        case .message(let message):
            sessionService.setLastMessageSyncTimestamp(
                Int64(message.timestamp.timeIntervalSince1970 * 1000)
            )
            NotificationCenter.default.post(
                name: .sanchrRealtimeMessageReceived,
                object: nil,
                userInfo: [
                    RealtimeNotificationKey.conversationId: message.conversationId,
                    RealtimeNotificationKey.message: message,
                ]
            )
            NotificationCenter.default.post(name: .sanchrConversationStateDidChange, object: nil)

        case .typing(let indicator):
            NotificationCenter.default.post(
                name: .sanchrRealtimeTypingChanged,
                object: nil,
                userInfo: [
                    RealtimeNotificationKey.conversationId: indicator.conversationID,
                    RealtimeNotificationKey.typing: indicator,
                ]
            )

        case .receipt(let receipt):
            NotificationCenter.default.post(
                name: .sanchrRealtimeReceiptUpdated,
                object: nil,
                userInfo: [
                    RealtimeNotificationKey.conversationId: receipt.conversationID,
                    RealtimeNotificationKey.receipt: receipt,
                ]
            )
            NotificationCenter.default.post(name: .sanchrConversationStateDidChange, object: nil)

        case .presence(let presence):
            NotificationCenter.default.post(
                name: .sanchrRealtimePresenceUpdated,
                object: nil,
                userInfo: [RealtimeNotificationKey.presence: presence]
            )

        case .preKeyCountLow:
            Task {
                try? await signalKeyManager.replenishPreKeys()
            }

        case .callOffer(let offer):
            callManager.handleIncomingCallOffer(offer)

        case .callLifecycle(let lifecycle):
            callManager.handleCallLifecycleEvent(lifecycle)
        }
    }
}
