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
    /// A peer's encrypted profile was fetched and decrypted, so a cached
    /// display name may now be stale. Unlike a conversation-state change this
    /// affects the contact join, so the list must re-run the normalizing fetch
    /// rather than reload raw cached rows.
    static let sanchrContactProfileResolved = Notification.Name("io.sanchr.realtime.contactProfileResolved")
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

    func postContactProfileResolved(userId: String) {
        post(
            name: .sanchrContactProfileResolved, object: nil,
            userInfo: [RealtimeNotificationKey.conversationId: userId])
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
    private(set) var presenceCache: [String: Sanchr_Messaging_PresenceUpdate] = [:]
    private var trackedPeerRefCounts: [String: Int] = [:]
    private var presenceExpiryTasks: [String: Task<Void, Never>] = [:]
    private var reconnectAttempt: Int = 0
    private let presenceExpiryNanoseconds: UInt64
    @ObservationIgnored private var networkCancellable: AnyCancellable?
    @ObservationIgnored private var privacyCancellable: AnyCancellable?

    init(
        messageRepository: MessageRepositoryProtocol,
        signalKeyManager: KeyManagerProtocol,
        sessionService: SessionService,
        callManager: CallEventRouting,
        privacySettings: PrivacySettingsCache,
        networkMonitor: NetworkMonitorProtocol,
        presenceExpiryNanoseconds: UInt64 = 75_000_000_000
    ) {
        self.messageRepository = messageRepository
        self.signalKeyManager = signalKeyManager
        self.sessionService = sessionService
        self.callManager = callManager
        self.privacySettings = privacySettings
        self.networkMonitor = networkMonitor
        self.presenceExpiryNanoseconds = presenceExpiryNanoseconds
        observeNetworkChanges()
        observePrivacyChanges()
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

    private func observePrivacyChanges() {
        privacyCancellable = NotificationCenter.default.publisher(for: .sanchrPrivacySettingsDidChange)
            .sink { [weak self] _ in
                self?.handlePrivacySettingsChanged()
            }
    }

    private func handlePrivacySettingsChanged() {
        guard sessionService.isAuthenticated else { return }

        heartbeatTask?.cancel()
        heartbeatTask = nil

        if privacySettings.sanchrModeEnabled {
            return
        }

        if privacySettings.onlineStatusVisible {
            sendP2PPresenceToTracked(status: .online)
            startP2PPresenceLoop()
        } else {
            sendP2PPresenceToTracked(status: .hidden)
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
                    _ = try await sessionService.refreshTokenIfExpiringSoon()
                    _ = try await messageRepository.flushPendingAcks()
                    let stream = try await messageRepository.openMessageStream()
                    SanchrLogger.chat.info("Realtime message stream opened")
                    // Successful open — reset the backoff curve.
                    self.reconnectAttempt = 0
                    // Catch-up sync: the stream only carries messages pushed while
                    // it is up. Anything sent during the gap between the previous
                    // stream dying and this one opening sits queued server-side
                    // and would otherwise wait for the next app-activation sync —
                    // in practice the stream is cut by an idle timeout every
                    // ~60s, so without this, messages that land in a reconnect
                    // gap appear minutes late or not at all this session.
                    Task { [weak self] in _ = await self?.syncNowResult() }
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
                    if Self.isUnauthenticated(error) {
                        do {
                            SanchrLogger.auth.info("Realtime stream unauthenticated; force-refreshing token before retry")
                            _ = try await sessionService.forceRefreshToken()
                            self.reconnectAttempt = 0
                        } catch {
                            SanchrLogger.auth.error("Realtime token refresh failed: \(error.localizedDescription)")
                        }
                    }
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
        presenceExpiryTasks.values.forEach { $0.cancel() }
        presenceExpiryTasks.removeAll()
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
        sendP2PPresenceToTracked(status: .online)
        startP2PPresenceLoop()
    }

    func enterBackground() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard sessionService.isAuthenticated else {
            stop()
            return
        }
        sendP2PPresenceToTracked(status: .offline)
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            stop()
        }
    }

    func trackPresencePeer(_ userId: String) {
        guard !userId.isEmpty else { return }
        let previousCount = trackedPeerRefCounts[userId] ?? 0
        trackedPeerRefCounts[userId] = previousCount + 1
        guard previousCount == 0 else { return }

        // Immediately announce our presence to the newly tracked peer
        sendP2PPresence(to: userId, status: .online)
    }

    func untrackPresencePeer(_ userId: String) {
        guard let count = trackedPeerRefCounts[userId] else { return }
        if count > 1 {
            trackedPeerRefCounts[userId] = count - 1
        } else {
            trackedPeerRefCounts.removeValue(forKey: userId)
        }
    }

    func cachedPresence(for userId: String) -> Sanchr_Messaging_PresenceUpdate? {
        presenceCache[userId]
    }

    func syncNowResult() async -> MessageSyncResult {
        guard sessionService.isAuthenticated else {
            return MessageSyncResult(
                appliedCount: 0,
                latestTimestamp: sessionService.lastMessageSyncTimestamp,
                appliedCountsByConversation: [:]
            )
        }

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
            return result
        } catch {
            SanchrLogger.sync.error("Realtime sync failed: \(error.localizedDescription)")
            return MessageSyncResult(
                appliedCount: 0,
                latestTimestamp: sessionService.lastMessageSyncTimestamp,
                appliedCountsByConversation: [:]
            )
        }
    }

    @discardableResult
    func syncNow() async -> Int {
        await syncNowResult().appliedCount
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
                self.applyPresenceUpdate(presence)
            }

        case .preKeyCountLow:
            Task {
                try? await signalKeyManager.replenishPreKeys()
            }

        case .callOffer(let offer):
            let outcome = await callManager.handleIncomingCallOffer(offer)
            if outcome != .transientFailure {
                await messageRepository.ackCallEvent(callId: offer.callID, kind: "offer")
            }

        case .callLifecycle(let lifecycle):
            _ = await callManager.handleCallLifecycleEvent(lifecycle)
            await messageRepository.ackCallEvent(callId: lifecycle.callID, kind: "lifecycle")

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

        case .sealedMessage:
            // Sealed messages are decrypted in the stream layer
            // (MessageRepository.openMessageStream) and yielded as
            // `.message`. This case is a defensive fallback that should
            // not be reached in normal operation.
            SanchrLogger.chat.warning("Received un-decoded sealed message in RealtimeService handle — this is unexpected")

        case .ignored:
            // Already fully handled during decode (e.g. a profile-key envelope).
            // Nothing to route.
            break
        }
    }

    /// Sends a sealed-sender P2P presence update to all currently tracked peers.
    private func sendP2PPresenceToTracked(status: Sanchr_Messaging_PresenceStatus) {
        let peers = Array(trackedPeerRefCounts.keys)
        guard !peers.isEmpty else { return }
        for peerId in peers {
            sendP2PPresence(to: peerId, status: status)
        }
    }

    /// Runs a 30-second loop broadcasting our online status to tracked peers
    /// (replaces the old server-heartbeat loop).
    private func startP2PPresenceLoop() {
        heartbeatTask?.cancel()
        guard !privacySettings.sanchrModeEnabled,
              privacySettings.onlineStatusVisible
        else {
            heartbeatTask = nil
            return
        }

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, sessionService.isAuthenticated else { return }
                sendP2PPresenceToTracked(status: .online)
            }
        }
    }

    private func sendP2PPresence(
        to peerId: String,
        status requestedStatus: Sanchr_Messaging_PresenceStatus
    ) {
        guard let status = effectivePresenceStatus(for: requestedStatus) else { return }
        let lastSeenMs = Int64(Date().timeIntervalSince1970 * 1000)
        Task {
            try? await messageRepository.sendP2PPresence(
                recipientUserId: peerId,
                statusCode: status,
                lastSeenMs: lastSeenMs
            )
        }
    }

    private func effectivePresenceStatus(
        for requestedStatus: Sanchr_Messaging_PresenceStatus
    ) -> Sanchr_Messaging_PresenceStatus? {
        if privacySettings.sanchrModeEnabled {
            return nil
        }

        if !privacySettings.onlineStatusVisible {
            return .hidden
        }

        return requestedStatus
    }

    @MainActor
    private func applyPresenceUpdate(_ presence: Sanchr_Messaging_PresenceUpdate) {
        presenceCache[presence.userID] = presence
        NotificationCenter.default.post(
            name: .sanchrRealtimePresenceUpdated,
            object: nil,
            userInfo: [RealtimeNotificationKey.presence: presence]
        )

        if presence.statusCode == .online {
            schedulePresenceExpiry(for: presence.userID)
        } else {
            presenceExpiryTasks[presence.userID]?.cancel()
            presenceExpiryTasks[presence.userID] = nil
        }
    }

    @MainActor
    private func schedulePresenceExpiry(for userId: String) {
        presenceExpiryTasks[userId]?.cancel()
        presenceExpiryTasks[userId] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.presenceExpiryNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.expireOnlinePresenceIfStillCurrent(userId: userId)
            }
        }
    }

    @MainActor
    private func expireOnlinePresenceIfStillCurrent(userId: String) {
        guard var presence = presenceCache[userId],
              presence.statusCode == .online
        else { return }

        presence.statusCode = .offline
        presence.status = "offline"
        presence.lastSeen = Int64(Date().timeIntervalSince1970 * 1000)
        presenceCache[userId] = presence
        presenceExpiryTasks[userId] = nil
        NotificationCenter.default.post(
            name: .sanchrRealtimePresenceUpdated,
            object: nil,
            userInfo: [RealtimeNotificationKey.presence: presence]
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

    private static func isUnauthenticated(_ error: Error) -> Bool {
        if let status = error as? GRPCStatus {
            return status.code == .unauthenticated
        }
        let nsError = error as NSError
        return nsError.domain == "io.grpc"
            && GRPCStatus.Code(rawValue: nsError.code) == .unauthenticated
    }
}
