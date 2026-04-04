import XCTest

@testable import Sanchr

final class RealtimeServiceTests: XCTestCase {
    func testSyncNowAdvancesHighWatermarkAndPostsConversationChange() async throws {
        let sessionService = try await makeAuthenticatedSessionService()
        let messageRepository = MockMessageRepository()
        messageRepository.syncResult = MessageSyncResult(appliedCount: 2, latestTimestamp: 1_750_000_123)

        let service = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: MockKeyManager(),
            sessionService: sessionService,
            callManager: MockCallEventRouter()
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

    func testRealtimeStreamRoutesEventsToNotificationsKeyRefreshAndCallHandlers() async throws {
        let sessionService = try await makeAuthenticatedSessionService()
        let messageRepository = MockMessageRepository()
        let keyManager = MockKeyManager()
        let callRouter = MockCallEventRouter()
        let service = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: keyManager,
            sessionService: sessionService,
            callManager: callRouter
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
        var typing = Vync_Messaging_TypingIndicator()
        typing.conversationID = "conversation-1"
        typing.isTyping = true
        let typingConversationID = typing.conversationID

        var preKeyCountLow = Vync_Messaging_PreKeyCountLow()
        preKeyCountLow.remainingCount = 1

        var offer = Vync_Messaging_CallOfferEvent()
        offer.callID = "call-1"
        offer.callerID = "remote-user"
        offer.callType = "voice"
        offer.sdpOffer = Data("offer".utf8)

        var lifecycle = Vync_Messaging_CallLifecycleEvent()
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
            let indicator = notification.userInfo?[RealtimeNotificationKey.typing] as? Vync_Messaging_TypingIndicator
            return indicator?.conversationID == typingConversationID
        }

        service.start()
        try await waitUntil { messageRepository.openStreamCallCount == 1 }
        XCTAssertEqual(messageRepository.flushPendingAcksCallCount, 1)

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

    private func makeAuthenticatedSessionService() async throws -> SessionService {
        let storage = MockSecureStorage()
        let service = SessionService(
            secureStorage: storage,
            authRepository: MockAuthRepository()
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
