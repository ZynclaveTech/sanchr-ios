import Combine
import Foundation
import GRPC
import SanchrShared

extension Notification.Name {
    static let sanchrConversationStateDidChange = Notification.Name("io.sanchr.realtime.conversationStateDidChange")
    static let sanchrRealtimeMessageReceived = Notification.Name("io.sanchr.realtime.messageReceived")
    static let sanchrRealtimeTypingChanged = Notification.Name("io.sanchr.realtime.typingChanged")
    static let sanchrRealtimeReceiptUpdated = Notification.Name("io.sanchr.realtime.receiptUpdated")
    static let sanchrRealtimePresenceUpdated = Notification.Name("io.sanchr.realtime.presenceUpdated")
    static let sanchrRealtimeReactionReceived = Notification.Name("io.sanchr.realtime.reactionReceived")
}

enum RealtimeNotificationKey {
    static let conversationId = "conversationId"
    static let message = "message"
    static let typing = "typing"
    static let receipt = "receipt"
    static let presence = "presence"
}

extension NotificationCenter {
    func postConversationStateDidChange(conversationId: String? = nil) {
        var userInfo: [AnyHashable: Any]?
        if let conversationId, !conversationId.isEmpty {
            userInfo = [RealtimeNotificationKey.conversationId: conversationId]
        }
        post(name: .sanchrConversationStateDidChange, object: nil, userInfo: userInfo)
    }
}

@Observable
final class RealtimeService: @unchecked Sendable {
    private let messageRepository: MessageRepositoryProtocol
    private let signalKeyManager: KeyManagerProtocol
    private let sessionService: SessionService
    private let callManager: CallEventRouting
    private let privacySettings: PrivacySettingsCache
    private let networkMonitor: NetworkMonitorProtocol

    private var streamTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var presenceCache: [String: Vync_Messaging_PresenceUpdate] = [:]
    private var trackedPeerIds: Set<String> = []
    private var reconnectAttempt: Int = 0
    @ObservationIgnored private var networkCancellable: AnyCancellable?

    init(
        messageRepository: MessageRepositoryProtocol,
        signalKeyManager: KeyManagerProtocol,
        sessionService: SessionService,
        callManager: CallEventRouting,
        privacySettings: PrivacySettingsCache,
        networkMonitor: NetworkMonitorProtocol
    ) {
        self.messageRepository = messageRepository
        self.signalKeyManager = signalKeyManager
        self.sessionService = sessionService
        self.callManager = callManager
        self.privacySettings = privacySettings
        self.networkMonitor = networkMonitor
        observeNetworkChanges()
    }

    /// Exponential backoff with 30% jitter and a 30s cap.
    /// attempt 0 ≈ 1s, attempt 1 ≈ 2s, ..., attempt 5+ ≈ 30s (± jitter).
    /// Made static/internal so unit tests can exercise it in isolation
    /// without driving the whole realtime loop.
    static func reconnectBackoff(attempt: Int) -> TimeInterval {
        let base: Double = 1.0
        let cap: Double = 30.0
        let exponential = min(cap, base * pow(2.0, Double(max(0, attempt))))
        let jitter = Double.random(in: 0...(exponential * 0.3))
        return exponential + jitter
    }

    private func observeNetworkChanges() {
        // `dropFirst()` is deliberate: `CurrentValueSubject` synchronously
        // delivers the current value to every new subscriber, but we
        // only care about real transitions here. The initial connectivity
        // state is already handled by the app launch path (SanchrApp's
        // scenePhase handler calls `enterForeground()` which in turn
        // calls `start()`), so auto-starting here would cause a double
        // stream open on every app launch.
        networkCancellable = networkMonitor.connectivityPublisher
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isConnected in
                guard let self else { return }
                if isConnected {
                    SanchrLogger.chat.info(
                        "realtime_reconnect: network up, resetting attempt counter"
                    )
                    self.reconnectAttempt = 0
                    // Poke start() in case the stream task fell out of
                    // its retry loop while the network was down.
                    if self.streamTask == nil {
                        self.start()
                    }
                } else {
                    SanchrLogger.chat.info(
                        "realtime_reconnect: network down, cancelling stream task"
                    )
                    // Cancel any in-flight stream/sleep so the retry loop
                    // exits cleanly instead of hammering gRPC into a dead
                    // socket.
                    self.streamTask?.cancel()
                    self.streamTask = nil
                }
            }
    }

    func start() {
        guard streamTask == nil, sessionService.isAuthenticated else { return }

        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, sessionService.isAuthenticated {
                do {
                    await MainActor.run {
                        self.isRunning = true
                    }
                    SanchrLogger.chat.info("Starting realtime message stream")
                    _ = try await messageRepository.flushPendingAcks()
                    let stream = try await messageRepository.openMessageStream()
                    SanchrLogger.chat.info("Realtime message stream opened")
                    // Successful open — reset the backoff curve.
                    self.reconnectAttempt = 0
                    for await event in stream {
                        guard !Task.isCancelled else { break }
                        await handle(event)
                    }

                    guard !Task.isCancelled, sessionService.isAuthenticated else {
                        break
                    }

                    SanchrLogger.chat.warning("Realtime message stream ended, retrying")
                } catch {
                    guard !Task.isCancelled else { break }
                    SanchrLogger.chat.error("Realtime stream failed: \(Self.detailedError(error))")
                }

                await MainActor.run {
                    self.isRunning = false
                }

                guard !Task.isCancelled, sessionService.isAuthenticated else {
                    break
                }

                let backoffSeconds = Self.reconnectBackoff(attempt: self.reconnectAttempt)
                self.reconnectAttempt += 1
                SanchrLogger.chat.info(
                    "realtime_reconnect attempt=\(self.reconnectAttempt) backoff_seconds=\(String(format: "%.2f", backoffSeconds))"
                )
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            }

            await MainActor.run {
                self.isRunning = false
                self.streamTask = nil
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        Task { @MainActor in
            self.isRunning = false
        }
        Task {
            await messageRepository.closeMessageStream()
        }
    }

    func enterForeground() {
        guard sessionService.isAuthenticated else { return }
        start()
        startHeartbeatLoop()
        Task {
            if privacySettings.canSendPresence {
                try? await sendPresenceHeartbeat(.foreground)
            }
            await refreshPresenceSnapshot(for: Array(trackedPeerIds))
        }
    }

    func enterBackground() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard sessionService.isAuthenticated else {
            stop()
            return
        }

        Task {
            if privacySettings.canSendPresence {
                try? await sendPresenceHeartbeat(.background)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            stop()
        }
    }

    func trackPresencePeer(_ userId: String) {
        guard !userId.isEmpty else { return }
        trackedPeerIds.insert(userId)
        Task {
            await refreshPresenceSnapshot(for: [userId])
        }
    }

    func untrackPresencePeer(_ userId: String) {
        trackedPeerIds.remove(userId)
    }

    func cachedPresence(for userId: String) -> Vync_Messaging_PresenceUpdate? {
        presenceCache[userId]
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
                await MainActor.run {
                    NotificationCenter.default.postConversationStateDidChange()
                }
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
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .sanchrRealtimeMessageReceived,
                    object: nil,
                    userInfo: [
                        RealtimeNotificationKey.conversationId: message.conversationId,
                        RealtimeNotificationKey.message: message,
                    ]
                )
                NotificationCenter.default.postConversationStateDidChange(
                    conversationId: message.conversationId
                )
            }

        case .typing(let indicator):
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .sanchrRealtimeTypingChanged,
                    object: nil,
                    userInfo: [
                        RealtimeNotificationKey.conversationId: indicator.conversationID,
                        RealtimeNotificationKey.typing: indicator,
                    ]
                )
            }

        case .receipt(let receipt):
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .sanchrRealtimeReceiptUpdated,
                    object: nil,
                    userInfo: [
                        RealtimeNotificationKey.conversationId: receipt.conversationID,
                        RealtimeNotificationKey.receipt: receipt,
                    ]
                )
                NotificationCenter.default.postConversationStateDidChange(
                    conversationId: receipt.conversationID
                )
            }

        case .presence(let presence):
            await MainActor.run {
                self.presenceCache[presence.userID] = presence
                NotificationCenter.default.post(
                    name: .sanchrRealtimePresenceUpdated,
                    object: nil,
                    userInfo: [RealtimeNotificationKey.presence: presence]
                )
            }

        case .preKeyCountLow:
            Task {
                try? await signalKeyManager.replenishPreKeys()
            }

        case .callOffer(let offer):
            callManager.handleIncomingCallOffer(offer)

        case .callLifecycle(let lifecycle):
            callManager.handleCallLifecycleEvent(lifecycle)

        case .reaction(let reaction):
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .sanchrRealtimeReactionReceived,
                    object: nil,
                    userInfo: [
                        RealtimeNotificationKey.conversationId: reaction.conversationID,
                        "reaction": reaction,
                    ]
                )
            }
        }
    }

    @discardableResult
    func refreshPresenceSnapshot(for userIds: [String]) async -> [Vync_Messaging_PresenceUpdate] {
        let uniqueUserIds = Array(Set(userIds.filter { !$0.isEmpty }))
        guard sessionService.isAuthenticated, !uniqueUserIds.isEmpty else { return [] }

        do {
            let updates = try await messageRepository.fetchPresenceSnapshot(userIds: uniqueUserIds)
            await MainActor.run {
                for update in updates {
                    self.presenceCache[update.userID] = update
                    NotificationCenter.default.post(
                        name: .sanchrRealtimePresenceUpdated,
                        object: nil,
                        userInfo: [RealtimeNotificationKey.presence: update]
                    )
                }
            }
            return updates
        } catch {
            SanchrLogger.chat.warning("Presence snapshot failed: \(error.localizedDescription)")
            return []
        }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, sessionService.isAuthenticated else { return }
                guard privacySettings.canSendPresence else { continue }
                try? await sendPresenceHeartbeat(.foreground)
            }
        }
    }

    private func sendPresenceHeartbeat(_ state: Vync_Messaging_DevicePresenceState) async throws {
        try await messageRepository.sendPresenceHeartbeat(
            deviceState: state,
            sentAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    private static func detailedError(_ error: Error) -> String {
        if let status = error as? GRPCStatus {
            return "gRPC \(status.code) (\(status.code.rawValue)): \(status.message ?? "no message")"
        }
        let nsError = error as NSError
        if nsError.domain == "io.grpc",
           let statusCode = GRPCStatus.Code(rawValue: nsError.code) {
            return "gRPC \(statusCode) (\(nsError.code)): \(nsError.localizedDescription)"
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }
}
