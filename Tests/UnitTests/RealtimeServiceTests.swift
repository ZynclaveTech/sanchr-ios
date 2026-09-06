import XCTest
import SanchrShared

@testable import Sanchr

final class RealtimeServiceTests: XCTestCase {
    func testSyncNowAdvancesHighWatermarkAndPostsConversationChange() async throws {
        let sessionService = try await makeAuthenticatedSessionService()
        let messageRepository = MockMessageRepository()
        messageRepository.syncResult = MessageSyncResult(
            appliedCount: 2,
            latestTimestamp: 1_750_000_123,
            appliedCountsByConversation: ["conversation-1": 2]
        )

        let service = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: MockKeyManager(),
            sessionService: sessionService,
            callManager: MockCallEventRouter(),
            privacySettings: PrivacySettingsCache(),
            networkMonitor: MockNetworkMonitor()
        )

        let notificationExpectation = expectation(
            forNotification: .sanchrConversationStateDidChange,
            object: nil
        )

        let applied = await service.syncNow()

        await fulfillment(of: [notificationExpectation], timeout: 1.0)
        XCTAssertEqual(applied, 2)
        XCTAssertEqual(messageRepository.syncedTimestamps, [0])
        XCTAssertEqual(messageRepository.flushPendingAcksCallCount, 1)
        XCTAssertEqual(sessionService.lastMessageSyncTimestamp, 1_750_000_123)
    }

    func testSyncNowResultIncludesAppliedConversationCounts() async throws {
        let sessionService = try await makeAuthenticatedSessionService()
        let messageRepository = MockMessageRepository()
        messageRepository.syncResult = MessageSyncResult(
            appliedCount: 3,
            latestTimestamp: 1_750_000_456,
            appliedCountsByConversation: [
                "conversation-1": 2,
                "conversation-2": 1,
            ]
        )

        let service = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: MockKeyManager(),
            sessionService: sessionService,
            callManager: MockCallEventRouter(),
            privacySettings: PrivacySettingsCache(),
            networkMonitor: MockNetworkMonitor()
        )

        let result = await service.syncNowResult()

        XCTAssertEqual(result.appliedCount, 3)
        XCTAssertEqual(result.latestTimestamp, 1_750_000_456)
        XCTAssertEqual(
            result.appliedCountsByConversation,
            ["conversation-1": 2, "conversation-2": 1]
        )
    }

    func testRealtimeStreamRoutesEventsToNotificationsKeyRefreshAndCallHandlers() async throws {
        let sessionService = try await makeAuthenticatedSessionService()
        let messageRepository = MockMessageRepository()
        let keyManager = MockKeyManager()
        let callRouter = MockCallEventRouter()
        let service = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: keyManager,
            sessionService: sessionService,
            callManager: callRouter,
            privacySettings: PrivacySettingsCache(),
            networkMonitor: MockNetworkMonitor()
        )

        let message = Message(
            id: "message-1",
            conversationId: "conversation-1",
            senderId: "remote-user",
            timestamp: Date(timeIntervalSince1970: 1_750_000_500),
            content: .text("hello"),
            status: .delivered,
            isOutgoing: false
        )
        var typing = Sanchr_Messaging_TypingIndicator()
        typing.conversationID = "conversation-1"
        typing.isTyping = true
        let typingConversationID = typing.conversationID

        var preKeyCountLow = Sanchr_Messaging_PreKeyCountLow()
        preKeyCountLow.remainingCount = 1

        var offer = Sanchr_Messaging_CallOfferEvent()
        offer.callID = "call-1"
        offer.callerID = "remote-user"
        offer.callType = "voice"
        offer.sdpOffer = Data("offer".utf8)

        var lifecycle = Sanchr_Messaging_CallLifecycleEvent()
        lifecycle.callID = "call-1"
        lifecycle.eventType = "ended"
        lifecycle.peerID = "remote-user"

        let messageExpectation = expectation(
            forNotification: .sanchrRealtimeMessageReceived,
            object: nil
        ) { notification in
            let receivedMessage = notification.userInfo?[RealtimeNotificationKey.message] as? Message
            return receivedMessage?.id == message.id
        }

        let typingExpectation = expectation(
            forNotification: .sanchrRealtimeTypingChanged,
            object: nil
        ) { notification in
            let indicator = notification.userInfo?[RealtimeNotificationKey.typing] as? Sanchr_Messaging_TypingIndicator
            return indicator?.conversationID == typingConversationID
        }

        service.start()
        try await waitUntil { messageRepository.openStreamCallCount == 1 }
        // At least one flush must happen before the stream opens, to drain acks
        // queued while the app was offline. `start()` also kicks off a catch-up
        // sync on its own task, and that flushes again to ack whatever the sync
        // just applied — so the exact count here is a race, not an invariant.
        XCTAssertGreaterThanOrEqual(messageRepository.flushPendingAcksCallCount, 1)

        messageRepository.emit(.message(message))
        messageRepository.emit(.typing(typing))
        messageRepository.emit(.preKeyCountLow(preKeyCountLow))
        messageRepository.emit(.callOffer(offer))
        messageRepository.emit(.callLifecycle(lifecycle))

        await fulfillment(of: [messageExpectation, typingExpectation], timeout: 1.0)
        try await waitUntil {
            keyManager.replenishPreKeysCallCount == 1
                && callRouter.offers.count == 1
                && callRouter.lifecycleEvents.count == 1
        }

        XCTAssertEqual(
            sessionService.lastMessageSyncTimestamp,
            Int64(message.timestamp.timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(callRouter.offers.first?.callID, "call-1")
        XCTAssertEqual(callRouter.lifecycleEvents.first?.eventType, "ended")
        XCTAssertGreaterThanOrEqual(messageRepository.flushPendingAcksCallCount, 2)

        service.stop()
        messageRepository.finishStream()
    }

    func testPresenceTrackingSendsHiddenWhenOnlineStatusDisabled() async throws {
        let sessionService = try await makeAuthenticatedSessionService()
        let messageRepository = MockMessageRepository()
        let privacySettings = PrivacySettingsCache()
        let service = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: MockKeyManager(),
            sessionService: sessionService,
            callManager: MockCallEventRouter(),
            privacySettings: privacySettings,
            networkMonitor: MockNetworkMonitor()
        )

        service.trackPresencePeer("peer-1")
        try await waitUntil { messageRepository.p2pPresenceSends.count == 1 }

        var settings = Sanchr_Settings_UserSettings()
        settings.readReceipts = true
        settings.typingIndicator = true
        settings.onlineStatusVisible = false
        settings.sanchrModeEnabled = false
        settings.profilePhotoVisibility = "everyone"
        privacySettings.update(from: settings)

        try await waitUntil { messageRepository.p2pPresenceSends.count == 2 }
        XCTAssertEqual(messageRepository.p2pPresenceSends.map(\.statusCode), [.online, .hidden])

        service.stop()
    }

    func testOnlinePresenceExpiresToOfflineLocally() async throws {
        let sessionService = try await makeAuthenticatedSessionService()
        let messageRepository = MockMessageRepository()
        let service = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: MockKeyManager(),
            sessionService: sessionService,
            callManager: MockCallEventRouter(),
            privacySettings: PrivacySettingsCache(),
            networkMonitor: MockNetworkMonitor(),
            presenceExpiryNanoseconds: 100_000_000
        )

        service.start()
        try await waitUntil { messageRepository.openStreamCallCount == 1 }
        try await waitUntil { messageRepository.streamContinuation != nil }

        var presence = Sanchr_Messaging_PresenceUpdate()
        presence.userID = "peer-1"
        presence.status = "online"
        presence.statusCode = .online
        messageRepository.emit(.presence(presence))

        // Read on the main actor, where the cache lives. Polling it from the
        // waitUntil closure's thread is what raced the expiry task's write.
        try await waitUntilOnMain {
            service.cachedPresence(for: "peer-1")?.statusCode == .online
        }
        try await waitUntilOnMain(timeoutNanoseconds: 300_000_000) {
            service.cachedPresence(for: "peer-1")?.statusCode == .offline
        }

        service.stop()
        messageRepository.finishStream()
    }

    private func makeAuthenticatedSessionService() async throws -> SessionService {
        let storage = MockSecureStorage()
        let service = SessionService(
            secureStorage: storage,
            authRepository: MockAuthRepository(),
            privacySettings: PrivacySettingsCache()
        )

        try await service.storeTokens(
            AuthTokens(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                expiresAt: Date().addingTimeInterval(3600),
                userId: "user-1",
                displayName: "Realtime User",
                phoneNumber: "+15550001111",
                avatarURL: "",
                deviceId: "9"
            )
        )

        return service
    }

    /// [waitUntil] for state that is isolated to the main actor.
    private func waitUntilOnMain(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !(await MainActor.run { condition() }) {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("condition not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Condition was not satisfied before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
