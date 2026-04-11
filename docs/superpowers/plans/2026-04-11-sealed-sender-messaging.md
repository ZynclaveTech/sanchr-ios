# Sealed Sender for Messaging — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MessageRepositoryImpl.sendMessage()`'s regular Signal send with the `sendSealedMessage` RPC so the server never learns sender identity on outgoing messages.

**Architecture:** `sealedSenderManager` is already injected into `MessageRepositoryImpl`. The change is one method body: wrap plaintext in `InnerPayload`, encrypt via Signal (same sessions), send via `sendSealedMessage` RPC with a delivery token. The server sees only `recipient_id + sealed ciphertext` — no sender identity. The receive path (`decodeSealedMessage`) already handles `SealedInboundMessage` and is untouched.

**Tech Stack:** Swift, SwiftProtobuf, LibSignalClient, GRPC-Swift, XCTest

**Known limitation (out of scope):** `SendSealedMessageRequest` has no `expiresAfterSecs` field — server-side disappearing-message enforcement is dropped for now; client-side timers remain. Follow-up: add `expires_after_secs` to the proto.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Shared/Repositories/MessageRepository.swift` | Modify | Replace encrypt+send block in `sendMessage()` |
| `Tests/UnitTests/MessageRepositorySealedSendTests.swift` | Create | Smoke test: verifies `sendSealedMessage` is called, `sendMessage` is not |

---

### Task 1: Write the failing test

**Files:**
- Create: `Tests/UnitTests/MessageRepositorySealedSendTests.swift`

- [ ] **Step 1: Create the test file**

```swift
// Tests/UnitTests/MessageRepositorySealedSendTests.swift
import XCTest
import SanchrShared
@testable import Sanchr

// MARK: - Spy messaging service

/// Tracks which send RPC was called. Implements only the two methods under test;
/// all others crash to surface accidental calls early.
private final class SpyMessagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol,
    @unchecked Sendable
{
    // Required by protocol — not used in these tests
    var channel: GRPCChannel { fatalError("not used") }
    var defaultCallOptions: CallOptions = CallOptions()
    var interceptors: Sanchr_Messaging_MessagingServiceClientInterceptorFactoryProtocol? = nil

    // Spies
    private(set) var sendSealedMessageCallCount = 0
    private(set) var sendMessageCallCount = 0

    func sendSealedMessage(
        _ request: Sanchr_Messaging_SendSealedMessageRequest,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Messaging_SendSealedMessageResponse {
        sendSealedMessageCallCount += 1
        var response = Sanchr_Messaging_SendSealedMessageResponse()
        response.serverTimestamp = 1_700_000_000_000
        return response
    }

    func sendMessage(
        _ request: Sanchr_Messaging_SendMessageRequest,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Messaging_SendMessageResponse {
        sendMessageCallCount += 1
        return Sanchr_Messaging_SendMessageResponse()
    }

    // ── All remaining protocol requirements — crash if unexpectedly called ──

    func messageStream<RequestStream>(
        _ requests: RequestStream, callOptions: CallOptions? = nil
    ) -> GRPCAsyncResponseStream<Sanchr_Messaging_ServerEvent>
    where RequestStream: AsyncSequence & Sendable, RequestStream.Element == Sanchr_Messaging_ClientEvent {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }

    func getSenderCertificate(_ request: Sanchr_Messaging_GetSenderCertificateRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_SenderCertificateResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func getDeliveryTokens(_ request: Sanchr_Messaging_GetDeliveryTokensRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_DeliveryTokenResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func markMessagesRead(_ request: Sanchr_Messaging_MarkReadRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_MarkReadResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func deleteMessage(_ request: Sanchr_Messaging_DeleteMessageRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_DeleteMessageResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func getConversations(_ request: Sanchr_Messaging_GetConversationsRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_GetConversationsResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func startConversation(_ request: Sanchr_Messaging_StartConversationRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_StartConversationResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func getMessages(_ request: Sanchr_Messaging_GetMessagesRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_GetMessagesResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func getPreKeyBundle(_ request: Sanchr_Messaging_GetPreKeyBundleRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_PreKeyBundleResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func uploadPreKeys(_ request: Sanchr_Messaging_UploadPreKeysRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_UploadPreKeysResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func getPresenceSnapshot(_ request: Sanchr_Messaging_GetPresenceSnapshotRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_PresenceSnapshotResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
    func getUserDevices(_ request: Sanchr_Messaging_GetUserDevicesRequest, callOptions: CallOptions? = nil) async throws -> Sanchr_Messaging_GetUserDevicesResponse {
        fatalError("SpyMessagingService: \(#function) must not be called in this test")
    }
}

// MARK: - Stub GRPC client

private final class StubGRPCClient: GRPCClientProtocol, @unchecked Sendable {
    let messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol
    init(messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol) {
        self.messagingService = messagingService
    }
    // Other services — not called in send path
    var callSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol {
        fatalError("not used") }
    var profileService: Sanchr_Profile_ProfileServiceAsyncClientProtocol {
        fatalError("not used") }
    var authService: Sanchr_Auth_AuthServiceAsyncClientProtocol {
        fatalError("not used") }
}

// MARK: - Stub LocalDatabase (minimal for send path)

private final class StubLocalDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    func fetchConversation(id: String) async throws -> Conversation? {
        Conversation(
            id: "conv-1",
            type: .direct,
            participants: [
                Participant(id: "alice", displayName: "Alice", isLocalUser: true),
                Participant(id: "bob",   displayName: "Bob",   isLocalUser: false),
            ],
            displayName: "Bob",
            lastMessage: nil,
            unreadCount: 0,
            avatarURL: nil,
            disappearingMessageSeconds: nil,
            draft: nil
        )
    }
    func saveMessage(_ message: Message) async throws {}
    // Remaining methods — crash to surface accidental calls
    func fetchMessages(conversationId: String, limit: Int, before: Date?) async throws -> [Message] { fatalError() }
    func fetchConversations() async throws -> [Conversation] { fatalError() }
    func updateMessageStatus(id: String, status: MessageStatus) async throws { fatalError() }
    func deleteMessage(id: String) async throws { fatalError() }
    func fetchMessage(id: String) async throws -> Message? { fatalError() }
    func saveConversation(_ conversation: Conversation) async throws { fatalError() }
    func updateConversationDraft(id: String, draft: String?) async throws { fatalError() }
    func updateConversationDisappearingSeconds(id: String, seconds: Int?) async throws { fatalError() }
    func deleteConversation(id: String) async throws { fatalError() }
    func fetchUnreadCount() async throws -> Int { fatalError() }
    func markMessagesRead(conversationId: String, upTo: Date) async throws { fatalError() }
    func pendingAcks() async throws -> [String] { fatalError() }
    func savePendingAck(messageId: String) async throws { fatalError() }
    func deletePendingAck(messageId: String) async throws { fatalError() }
    func allConversationIds() async throws -> [String] { fatalError() }
}

// MARK: - Stub Signal protocol (returns one fake device message per call)

private final class StubSignalProtocol: SignalProtocolManagerProtocol, @unchecked Sendable {
    let localUserId: String = "alice"
    func encryptForAllDevices(plaintext: Data, recipientId: String) async throws
        -> [Sanchr_Messaging_DeviceMessage]
    {
        var dm = Sanchr_Messaging_DeviceMessage()
        dm.recipientID = recipientId
        dm.deviceID = 1
        dm.ciphertext = Data("fake-ciphertext".utf8)
        return [dm]
    }
    func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data { plaintext }
    func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data { ciphertext }
    func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { Data() }
    func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
        throw AppError.decryptionFailed(reason: "not used") }
    func establishSession(with userId: String, deviceId: Int32) async throws {}
    func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
    func hasSession(with userId: String) -> Bool { true }
    func resetSession(with userId: String, deviceId: Int32) throws {}
    func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
    func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
    func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
    func markIdentityVerified(userId: String) {}
    func isIdentityVerified(userId: String) -> Bool { false }
    func localIdentityKeyData() throws -> Data { Data() }
    func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
}

// MARK: - Stub SealedSenderManager

private final class StubSealedSenderManager: SealedSenderManagerProtocol, @unchecked Sendable {
    func acquireDeliveryToken() async throws -> Data { Data("tok".utf8) }
    func getSenderCertificate() async throws -> Data { Data() }
    func encodeInnerPayload(conversationId: String, contentType: String, content: Data, isSync: Bool) throws -> Data {
        content  // pass-through for test simplicity
    }
    func decodeInnerPayload(_ data: Data) throws -> InnerPayload {
        InnerPayload(conversationId: "", contentType: "", content: Data(), isSync: false)
    }
    static func isInnerPayload(_ data: Data) -> Bool { false }
    func replenishIfNeeded() async {}
}

// MARK: - Tests

final class MessageRepositorySealedSendTests: XCTestCase {

    private func makeRepo(spyService: SpyMessagingService) -> MessageRepositoryImpl {
        MessageRepositoryImpl(
            grpcClient: StubGRPCClient(messagingService: spyService),
            localDatabase: StubLocalDatabase(),
            signalProtocol: StubSignalProtocol(),
            sealedSenderManager: StubSealedSenderManager(),
            chatVaultPolicyMirror: ChatVaultPolicyMirror(),
            vaultRepository: MockVaultRepository(),
            mediaDownloadManager: MediaDownloadManager(),
            currentUserIdProvider: { "alice" },
            privacySettings: PrivacySettingsCache()
        )
    }

    /// After the sealed-sender migration, `sendMessage` must call
    /// `sendSealedMessage` on the messaging service — never the plain `sendMessage` RPC.
    func test_sendMessage_callsSealedRPC_notRegularRPC() async throws {
        let spy = SpyMessagingService()
        let repo = makeRepo(spyService: spy)
        let message = Message(
            id: "msg-1",
            conversationId: "conv-1",
            senderId: "alice",
            timestamp: Date(),
            content: .text("hello"),
            status: .sending,
            isOutgoing: true,
            replyToMessageId: nil,
            expiresAt: nil
        )

        _ = try await repo.sendMessage(message)

        XCTAssertEqual(spy.sendSealedMessageCallCount, 1,
            "sendSealedMessage must be called exactly once")
        XCTAssertEqual(spy.sendMessageCallCount, 0,
            "plain sendMessage RPC must NOT be called — sender identity must be hidden from server")
    }

    /// The delivery token must be consumed on every send — proves the token is
    /// actually threaded through the request rather than acquired and discarded.
    func test_sendMessage_acquiresDeliveryToken() async throws {
        final class TrackingTokenManager: StubSealedSenderManager {
            private(set) var acquireCallCount = 0
            override func acquireDeliveryToken() async throws -> Data {
                acquireCallCount += 1
                return Data("tok".utf8)
            }
        }

        let spy = SpyMessagingService()
        let tokenManager = TrackingTokenManager()
        let repo = MessageRepositoryImpl(
            grpcClient: StubGRPCClient(messagingService: spy),
            localDatabase: StubLocalDatabase(),
            signalProtocol: StubSignalProtocol(),
            sealedSenderManager: tokenManager,
            chatVaultPolicyMirror: ChatVaultPolicyMirror(),
            vaultRepository: MockVaultRepository(),
            mediaDownloadManager: MediaDownloadManager(),
            currentUserIdProvider: { "alice" },
            privacySettings: PrivacySettingsCache()
        )
        let message = Message(
            id: "msg-2",
            conversationId: "conv-1",
            senderId: "alice",
            timestamp: Date(),
            content: .text("hi"),
            status: .sending,
            isOutgoing: true,
            replyToMessageId: nil,
            expiresAt: nil
        )

        _ = try await repo.sendMessage(message)

        XCTAssertEqual(tokenManager.acquireCallCount, 1,
            "A delivery token must be acquired for every outgoing message")
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails (before the implementation)**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/MessageRepositorySealedSendTests \
  2>&1 | grep -E "FAILED|PASSED|error:|warning: |test_send"
```

Expected: Both tests **FAIL** — `sendSealedMessageCallCount` is 0 because the implementation still uses `sendMessage`.

---

### Task 2: Implement the sealed send path

**Files:**
- Modify: `Shared/Repositories/MessageRepository.swift`

Read the file before editing (CLAUDE.md rule 9 — always re-read before edit).

- [ ] **Step 1: Re-read `sendMessage()` to lock in current content**

Read lines 168–243 of `Shared/Repositories/MessageRepository.swift`.

- [ ] **Step 2: Replace the encrypt+RPC block**

In `sendMessage()`, find and replace the block that:
1. Calls `signalProtocol.encryptForAllDevices(plaintext:recipientId:)` in a loop
2. Builds `Sanchr_Messaging_SendMessageRequest`
3. Calls `grpcClient.messagingService.sendMessage(request)`

**Old block (lines roughly 183–215):**
```swift
var deviceMessages: [Sanchr_Messaging_DeviceMessage] = []
for peerId in peerIds {
    let perPeer = try await signalProtocol.encryptForAllDevices(
        plaintext: plaintext,
        recipientId: peerId
    )
    deviceMessages.append(contentsOf: perPeer)
}

// 3. Send encrypted message via gRPC
var request = Sanchr_Messaging_SendMessageRequest()
request.conversationID = message.conversationId
request.deviceMessages = deviceMessages
request.contentType = Self.contentTypeString(for: message.content)
if let expiresAt = message.expiresAt {
    request.expiresAfterSecs = Int64(expiresAt.timeIntervalSinceNow)
}

let response = try await grpcClient.messagingService.sendMessage(request)
```

**New block:**
```swift
// 3. Wrap plaintext in InnerPayload and encrypt via sealed sender path.
//    The server sees only delivery_token + per-device ciphertext; sender_id is
//    never transmitted — it stays hidden behind the delivery token.
let contentType = Self.contentTypeString(for: message.content)
let innerPayload = try sealedSenderManager.encodeInnerPayload(
    conversationId: message.conversationId,
    contentType: contentType,
    content: plaintext,
    isSync: false
)
let deliveryToken = try await sealedSenderManager.acquireDeliveryToken()

var sealedDeviceMessages: [Sanchr_Messaging_SealedDeviceMessage] = []
for peerId in peerIds {
    let encrypted = try await signalProtocol.encryptForAllDevices(
        plaintext: innerPayload,
        recipientId: peerId
    )
    for dm in encrypted {
        var sdm = Sanchr_Messaging_SealedDeviceMessage()
        sdm.recipientID = dm.recipientID
        sdm.deviceID = dm.deviceID
        sdm.sealedEnvelope = dm.ciphertext
        sealedDeviceMessages.append(sdm)
    }
}

var request = Sanchr_Messaging_SendSealedMessageRequest()
request.deliveryToken = deliveryToken
request.deviceMessages = sealedDeviceMessages
// NOTE: SendSealedMessageRequest has no expiresAfterSecs field — server-side
// disappearing-message enforcement is not applied on the sealed path.
// Client-side timers remain active. Follow-up: add expires_after_secs to proto.

let response = try await grpcClient.messagingService.sendSealedMessage(request)

// Schedule background token pool replenishment (fire-and-forget).
Task { await sealedSenderManager.replenishIfNeeded() }
```

- [ ] **Step 3: Update the response handling block**

`SendSealedMessageResponse` has only `serverTimestamp` (no `messageID`). Find the block that reads `response.messageID` and replace it.

**Old:**
```swift
let updatedMessage = Message(
    id: response.messageID.isEmpty ? message.id : response.messageID,
    conversationId: message.conversationId,
    senderId: message.senderId,
    timestamp: serverTimestamp,
    content: message.content,
    status: .sent,
    isOutgoing: message.isOutgoing,
    replyToMessageId: message.replyToMessageId,
    expiresAt: message.expiresAt
)
```

**New:**
```swift
// Sealed responses carry no messageID — the client-generated UUID is canonical.
let updatedMessage = Message(
    id: message.id,
    conversationId: message.conversationId,
    senderId: message.senderId,
    timestamp: serverTimestamp,
    content: message.content,
    status: .sent,
    isOutgoing: message.isOutgoing,
    replyToMessageId: message.replyToMessageId,
    expiresAt: message.expiresAt
)
```

- [ ] **Step 4: Read the modified `sendMessage()` back to verify the edit applied correctly**

Read lines 168–250 of `Shared/Repositories/MessageRepository.swift`. Confirm:
- `sealedSenderManager.encodeInnerPayload` call is present
- `sealedSenderManager.acquireDeliveryToken` call is present
- `Sanchr_Messaging_SendSealedMessageRequest` is used (not `SendMessageRequest`)
- `grpcClient.messagingService.sendSealedMessage(request)` is called
- No reference to `sendMessage(request)` remains in this method
- No reference to `response.messageID` remains

---

### Task 3: Run the tests and fix any compilation errors

- [ ] **Step 1: Run the type-checker first**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded` with no errors. If there are errors, read the exact error lines and fix the offending code before proceeding.

- [ ] **Step 2: Run the new sealed send tests**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/MessageRepositorySealedSendTests \
  2>&1 | grep -E "FAILED|PASSED|error:|test_send"
```

Expected: Both tests **PASS**.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "FAILED|passed|failed" | tail -5
```

Expected: Same pass count as before (140+), 0 new failures.

---

### Task 4: Commit

- [ ] **Step 1: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add \
  Shared/Repositories/MessageRepository.swift \
  Tests/UnitTests/MessageRepositorySealedSendTests.swift
git commit -m "$(cat <<'EOF'
feat: sealed sender for outgoing messages — server no longer learns sender identity

Replaces the regular SignalProtocol+sendMessage path in MessageRepositoryImpl
with sendSealedMessage: plaintext is wrapped in an InnerPayload, encrypted via
the same Signal sessions, and sent with a delivery token. The server sees only
recipient_id and per-device ciphertext; sender_id is never transmitted.

Receive path (decodeSealedMessage) was already handling SealedInboundMessage
and is unchanged. DependencyContainer is unchanged (SealedSenderManager was
already injected).

Known gap: SendSealedMessageRequest has no expiresAfterSecs field —
server-side disappearing-message enforcement is suspended on the sealed path.
Client-side timers remain active. Follow-up: add field to proto.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- ✅ Hard cutover: `sendMessage` RPC no longer called from iOS client
- ✅ `sealedSenderManager` reused — no DependencyContainer changes
- ✅ Receive path untouched
- ✅ Two tests: RPC spy + delivery token call tracking
- ✅ Response handling updated (no `messageID` in sealed response)
- ✅ Background token replenishment (`replenishIfNeeded`) included

**Known gaps documented:**
- `expiresAfterSecs` gap noted inline and in commit message
- Self-sync (`isSync: true` for own other devices) is out of scope (consistent with current behavior)
