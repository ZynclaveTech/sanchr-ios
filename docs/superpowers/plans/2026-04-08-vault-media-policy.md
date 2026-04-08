# Per-Chat Vault Media Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the three Vault Media toggles in `ConversationInfoView` actually persist per-chat, enforce per-chat, and propagate per-chat — Auto-Vault Incoming, View Once, and Screenshot Protection — with **zero proto/backend changes**.

**Architecture:** A new `ChatVaultPolicyService` (`@Observable @MainActor`) on `DependencyContainer` owns per-chat policy storage. A sibling `ChatVaultPolicyMirror` (`NSLock`-protected, `Sendable`) is read by the background realtime decode path so it never blocks on the main actor. View-once is a single optional `Bool` field on `MediaAttachment` that rides inside the encrypted envelope. Receiver enforcement is three isolated edits: auto-vault routing in `MessageRepositoryImpl.decodeMessage`, view-once gallery + delete-on-dismiss in `MediaGalleryView`, and a `screenshotDetected` system event sent via a new `MessageRepository.sendSystemEvent` method.

**Tech Stack:** SwiftUI + GRDB (SQLCipher), `@Observable`, `NSLock` for cross-actor mirror, existing `VaultRepository.uploadItem` for vault routing, existing `ScreenshotProtectionModifier`, existing `MediaGalleryView` from the bubble-viewers feature.

**Spec:** `docs/superpowers/specs/2026-04-08-vault-media-policy-design.md`

---

## Spec deviations called out upfront

1. **Auto-vault is async, not inline.** The spec sketched routing as a synchronous "decide before save" branch in `decodeMessage`. In practice the receive path can't block on a download + upload round-trip per message — it'd starve the realtime stream. The plan implements auto-vault as a fire-and-forget background `Task` that:
   1. Persists the original message normally first (so the row exists and the user sees it).
   2. Spawns a vault upload `Task` that on success replaces the row with a `.system(.autoVaulted)` tombstone, and on failure leaves the original.
   This is strictly better than the spec's inline version: the receiver never stalls, vault failures degrade gracefully, and the policy check still runs synchronously off the lock-protected mirror.

2. **`fetchMessageById` is added** as a new `LocalDatabaseProtocol` method. The spec hand-waved this; the plan adds it explicitly because `deleteViewOnceMessage` needs to read the row to find the cached file path before wiping.

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `SanchrShared/Models/ChatVaultPolicy.swift` | Value type + `defaults(for:)` factory |
| `SanchrShared/Messaging/VaultPolicyResolving.swift` | Cross-isolation protocol seam used by `MessageSender` |
| `Shared/Services/ChatVaultPolicyService.swift` | `@Observable @MainActor` resolver + `ChatVaultPolicyMirror` (lock-protected sibling) |
| `Shared/Services/MainAppVaultPolicyResolver.swift` | Adapter that hops `@MainActor` so the actor-isolated `MessageSender` can read the policy |
| `Shared/Services/NoopVaultPolicyResolver.swift` | Used by the share extension; always returns defaults |
| `Tests/UnitTests/Features/Chats/ChatVaultPolicyServiceTests.swift` | Cache + load + set + notification + mirror + idempotency |
| `Tests/UnitTests/Features/Chats/ChatVaultRoutingTests.swift` | Auto-vault routing branch with policy variants |
| `Tests/UnitTests/Features/Chats/ChatVaultPolicyMirrorTests.swift` | Lock + cross-thread read of mirror |
| `Tests/UnitTests/Features/Chats/MediaAttachmentViewOnceCodableTests.swift` | JSON round-trip for the new `isViewOnce` field |

### Modified files

| Path | Change |
|---|---|
| `SanchrShared/Persistence/DatabaseSchema.swift` | Register `v5_chat_vault_policy` migration |
| `SanchrShared/Persistence/DatabaseRecords.swift` | New `ChatVaultPolicyRecord` GRDB record |
| `SanchrShared/Persistence/LocalDatabase.swift` | New `fetchVaultPolicy` / `setVaultPolicy` / `clearVaultPolicy` / `fetchMessageById` methods + protocol entries + failing-mock stubs |
| `SanchrShared/Models/Message.swift` | `MediaAttachment.isViewOnce: Bool?` field; `SystemEvent` adds `.viewOnceConsumed` and `.autoVaulted` cases |
| `SanchrShared/Messaging/MessageSender.swift` | New `vaultPolicyResolver` dependency on init; `sendMedia` reads policy and stamps `isViewOnce`; new `sendSystemEvent` method |
| `App/DependencyContainer.swift` | Expose `chatVaultPolicy: ChatVaultPolicyService`, `vaultPolicyResolver: VaultPolicyResolving`; pass resolver into `messageSender` and `messageRepository` constructors |
| `Shared/Repositories/MessageRepository.swift` | Inject `ChatVaultPolicyMirror` + `VaultRepositoryProtocol`; insert auto-vault routing in `decodeMessage`; new `deleteViewOnceMessage(messageId:)` and `sendSystemEvent(_:conversationId:)` methods + protocol entries |
| `Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift` | View-once enforcement: `anyViewOnceVisible` gate, `ScreenshotProtectionModifier`, `userDidTakeScreenshotNotification` listener, `openedViewOnceItems` tracking, `.onDisappear` delete |
| `Features/Chats/Presentation/ChatDetailView.swift` | `MessageBubble.systemEventLabel(_:)` adds `.viewOnceConsumed` + `.autoVaulted`; `ChatDetailView.task` warms `chatVaultPolicy.loadPolicy(conversationId:)` |
| `Features/Chats/Presentation/ConversationInfoView.swift` | `VaultMediaView` rewrite; `init(conversationId:)`; nav site update |
| `Tests/UnitTests/MessageSenderTests.swift` | Extend `FakeLocalDatabase` with new methods; add `MessageSenderViewOnceTests` cases |
| `SanchrShareExtension/Send/ShareSendCoordinator.swift` | Pass `NoopVaultPolicyResolver()` into the `MessageSender` it constructs |

### Files explicitly NOT touched

- Any `.proto` file or `SanchrShared/Generated/`.
- `VerifySecurityCodeView`, `WallpaperPainter`, `ChatAppearanceService` and any of the conversation-info / wallpaper code.
- `Features/Vault/Presentation/VaultView.swift` browsing surface — auto-vaulted items appear there unchanged via the existing fetch path.
- Any view that already uses Liquid Glass APIs the user has added.

---

## Task Breakdown

Tasks group into seven phases. Every phase ends with a build + commit gate. Standard build verification command for **all** tasks unless stated otherwise:

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
  /opt/homebrew/bin/xcodegen generate 2>&1 | tail -1 && \
  xcodebuild -project Sanchr.xcodeproj -scheme Sanchr \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -3
```

Expected last line: `** BUILD SUCCEEDED **`. Skip `xcodegen generate` for in-place file edits; run it whenever a NEW file is added.

---

## Phase 1 — Data model + value types

### Task 1: `ChatVaultPolicy` value type

**Files:**
- Create: `ios/Sanchr-iOS/SanchrShared/Models/ChatVaultPolicy.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Per-chat vault policy. All three flags default to off; flipping a
/// toggle in the per-chat Vault Media UI persists a row in the
/// `chatVaultPolicy` SQLCipher table. There is no global merge — every
/// chat starts at defaults and only diverges when the user touches
/// the toggles for that specific chat.
public struct ChatVaultPolicy: Equatable, Sendable {
    public let conversationId: String
    public let autoVaultIncoming: Bool
    public let viewOnceOutgoing: Bool
    public let screenshotProtection: Bool

    public init(
        conversationId: String,
        autoVaultIncoming: Bool,
        viewOnceOutgoing: Bool,
        screenshotProtection: Bool
    ) {
        self.conversationId = conversationId
        self.autoVaultIncoming = autoVaultIncoming
        self.viewOnceOutgoing = viewOnceOutgoing
        self.screenshotProtection = screenshotProtection
    }

    /// All-off default for chats with no persisted row yet.
    public static func defaults(for conversationId: String) -> ChatVaultPolicy {
        ChatVaultPolicy(
            conversationId: conversationId,
            autoVaultIncoming: false,
            viewOnceOutgoing: false,
            screenshotProtection: false
        )
    }
}
```

- [ ] **Step 2: Regenerate Xcode project**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && /opt/homebrew/bin/xcodegen generate
```

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add SanchrShared/Models/ChatVaultPolicy.swift && \
git commit -m "$(cat <<'EOF'
feat(shared): add ChatVaultPolicy value type

Per-chat vault policy with three Bool flags (autoVaultIncoming,
viewOnceOutgoing, screenshotProtection) and a defaults(for:) factory
returning all-off. Equatable + Sendable so the @Observable resolver
in Phase 2 can hold and propagate it.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `v5_chat_vault_policy` migration + GRDB record

**Files:**
- Modify: `ios/Sanchr-iOS/SanchrShared/Persistence/DatabaseSchema.swift`
- Modify: `ios/Sanchr-iOS/SanchrShared/Persistence/DatabaseRecords.swift`

- [ ] **Step 1: Register the migration**

In `SanchrShared/Persistence/DatabaseSchema.swift`, find the `v4_chat_appearance_overrides` migration block (the one before `return migrator`). Insert AFTER its closing brace and BEFORE `return migrator`:

```swift
        migrator.registerMigration("v5_chat_vault_policy") { db in
            try db.create(table: "chatVaultPolicy", ifNotExists: true) { t in
                t.primaryKey("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("autoVaultIncoming", .boolean).notNull().defaults(to: false)
                t.column("viewOnceOutgoing", .boolean).notNull().defaults(to: false)
                t.column("screenshotProtection", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
            }
        }
```

- [ ] **Step 2: Add the GRDB record at the bottom of `DatabaseRecords.swift`**

Append to the end of the file:

```swift
// MARK: - Chat Vault Policy

public struct ChatVaultPolicyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "chatVaultPolicy"

    public var conversationId: String
    public var autoVaultIncoming: Bool
    public var viewOnceOutgoing: Bool
    public var screenshotProtection: Bool
    public var updatedAt: Date

    public init(
        conversationId: String,
        autoVaultIncoming: Bool,
        viewOnceOutgoing: Bool,
        screenshotProtection: Bool,
        updatedAt: Date
    ) {
        self.conversationId = conversationId
        self.autoVaultIncoming = autoVaultIncoming
        self.viewOnceOutgoing = viewOnceOutgoing
        self.screenshotProtection = screenshotProtection
        self.updatedAt = updatedAt
    }

    public func toDomain() -> ChatVaultPolicy {
        ChatVaultPolicy(
            conversationId: conversationId,
            autoVaultIncoming: autoVaultIncoming,
            viewOnceOutgoing: viewOnceOutgoing,
            screenshotProtection: screenshotProtection
        )
    }

    public static func from(_ policy: ChatVaultPolicy, now: Date = Date()) -> ChatVaultPolicyRecord {
        ChatVaultPolicyRecord(
            conversationId: policy.conversationId,
            autoVaultIncoming: policy.autoVaultIncoming,
            viewOnceOutgoing: policy.viewOnceOutgoing,
            screenshotProtection: policy.screenshotProtection,
            updatedAt: now
        )
    }
}
```

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add SanchrShared/Persistence/DatabaseSchema.swift \
        SanchrShared/Persistence/DatabaseRecords.swift && \
git commit -m "$(cat <<'EOF'
feat(persistence): add v5_chat_vault_policy migration + record

New chatVaultPolicy sibling table keyed by conversationId with FK
cascade-on-delete to conversation. Three boolean columns default to
false; non-null updatedAt for future eviction logic.

ChatVaultPolicyRecord GRDB Codable+PersistableRecord with
toDomain / from(_:) helpers mirrors the ChatAppearanceOverrideRecord
shape.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `LocalDatabase` vault policy methods + `fetchMessageById`

**Files:**
- Modify: `ios/Sanchr-iOS/SanchrShared/Persistence/LocalDatabase.swift`
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/MessageSenderTests.swift` (FakeLocalDatabase)

- [ ] **Step 1: Add the protocol entries**

In `SanchrShared/Persistence/LocalDatabase.swift`, find the `// MARK: - Chat Appearance Overrides` block on `LocalDatabaseProtocol` (around line 45 from the previous feature). After its three `func ...` lines and BEFORE `// MARK: - Lifecycle`, add:

```swift
    // MARK: - Chat Vault Policy

    func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy?
    func setVaultPolicy(_ policy: ChatVaultPolicy) async throws
    func clearVaultPolicy(conversationId: String) async throws

    // MARK: - Message Lookup

    func fetchMessageById(_ messageId: String) async throws -> Message?
```

- [ ] **Step 2: Implement the methods on `LocalDatabase`**

Find the existing `clearAppearanceOverride` implementation (added in the conversation-info rework). After its closing brace, add:

```swift
    // MARK: - Chat Vault Policy

    public func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? {
        try await dbPool.read { db in
            try ChatVaultPolicyRecord
                .fetchOne(db, key: conversationId)?
                .toDomain()
        }
    }

    public func setVaultPolicy(_ policy: ChatVaultPolicy) async throws {
        try await dbPool.write { db in
            let record = ChatVaultPolicyRecord.from(policy)
            try record.save(db, onConflict: Database.ConflictResolution.replace)
        }
    }

    public func clearVaultPolicy(conversationId: String) async throws {
        _ = try await dbPool.write { db in
            try ChatVaultPolicyRecord
                .filter(Column("conversationId") == conversationId)
                .deleteAll(db)
        }
    }

    // MARK: - Message Lookup

    public func fetchMessageById(_ messageId: String) async throws -> Message? {
        try await dbPool.read { db in
            try MessageRecord
                .fetchOne(db, key: messageId)?
                .toDomain()
        }
    }
```

If `MessageRecord.fetchOne(db, key:)` doesn't exist by that exact name (the existing fetch path may use a different lookup), grep for `MessageRecord` in `DatabaseRecords.swift` to confirm the type name and adapt the call. The single-row primary-key fetch is the goal.

- [ ] **Step 3: Add stubs to the failing-mock at the bottom of `LocalDatabase.swift`**

Find the `class FailingLocalDatabase: LocalDatabaseProtocol` block. After the existing `clearAppearanceOverride` line, add:

```swift
    public func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? { throw error }
    public func setVaultPolicy(_ policy: ChatVaultPolicy) async throws { throw error }
    public func clearVaultPolicy(conversationId: String) async throws { throw error }
    public func fetchMessageById(_ messageId: String) async throws -> Message? { throw error }
```

- [ ] **Step 4: Add the methods to `FakeLocalDatabase` in `Tests/UnitTests/MessageSenderTests.swift`**

`FakeLocalDatabase` uses an extension `extension LocalDatabaseProtocol { ... }` of crash-on-call default impls (see `MessageSenderTests.swift:17`). Find the existing `extension LocalDatabaseProtocol` block. After the existing `clearAppearanceOverride` line, add:

```swift
    public func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? { FakeDBUnused.crash() }
    public func setVaultPolicy(_ policy: ChatVaultPolicy) async throws { FakeDBUnused.crash() }
    public func clearVaultPolicy(conversationId: String) async throws { FakeDBUnused.crash() }
    public func fetchMessageById(_ messageId: String) async throws -> Message? { FakeDBUnused.crash() }
```

- [ ] **Step 5: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add SanchrShared/Persistence/LocalDatabase.swift \
        Tests/UnitTests/MessageSenderTests.swift && \
git commit -m "$(cat <<'EOF'
feat(persistence): vault policy + fetchMessageById on LocalDatabase

New fetchVaultPolicy / setVaultPolicy / clearVaultPolicy methods on
the protocol + impl, plus a fetchMessageById single-row lookup that
deleteViewOnceMessage will need in Phase 4 to find the cached file
path before wiping.

FakeLocalDatabase + FailingLocalDatabase get crash-on-call /
throw-on-call stubs for the four new methods.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 1.**

---

## Phase 2 — Resolver service + container plumbing

### Task 4: `ChatVaultPolicyMirror` (lock-protected sibling)

**Files:**
- Create: `ios/Sanchr-iOS/Shared/Services/ChatVaultPolicyService.swift` (mirror only — the resolver lands in Task 5)
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/ChatVaultPolicyMirrorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/UnitTests/Features/Chats/ChatVaultPolicyMirrorTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

final class ChatVaultPolicyMirrorTests: XCTestCase {

    func test_writeThenRead_returnsValue() {
        let mirror = ChatVaultPolicyMirror()
        let policy = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: true
        )
        mirror.write(policy)
        XCTAssertEqual(mirror.policy(for: "c1"), policy)
    }

    func test_unknownConversationId_returnsNil() {
        let mirror = ChatVaultPolicyMirror()
        XCTAssertNil(mirror.policy(for: "nope"))
    }

    func test_remove_clearsValue() {
        let mirror = ChatVaultPolicyMirror()
        mirror.write(ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: false
        ))
        mirror.remove(conversationId: "c1")
        XCTAssertNil(mirror.policy(for: "c1"))
    }

    func test_concurrentWritesAndReads_doNotCrash() async {
        let mirror = ChatVaultPolicyMirror()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    mirror.write(ChatVaultPolicy(
                        conversationId: "c\(i % 5)",
                        autoVaultIncoming: i.isMultiple(of: 2),
                        viewOnceOutgoing: false,
                        screenshotProtection: false
                    ))
                    _ = mirror.policy(for: "c\(i % 5)")
                }
            }
        }
        // Survives — that's the assertion. NSLock-protected storage
        // should never crash under concurrent writes/reads.
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/ChatVaultPolicyMirrorTests 2>&1 | grep "error:" | head
```

Expected: `cannot find 'ChatVaultPolicyMirror' in scope`.

- [ ] **Step 3: Create the mirror file with only the mirror class**

Create `Shared/Services/ChatVaultPolicyService.swift` with just the mirror for now (the @Observable resolver lands in Task 5):

```swift
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
```

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/ChatVaultPolicyMirrorTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. (If sim NIO is broken, fall back to building the main target.)

- [ ] **Step 5: Regenerate project + build**

```bash
/opt/homebrew/bin/xcodegen generate 2>&1 | tail -1
```

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Shared/Services/ChatVaultPolicyService.swift \
        Tests/UnitTests/Features/Chats/ChatVaultPolicyMirrorTests.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): add ChatVaultPolicyMirror lock-protected sibling

NSLock-protected dictionary keyed by conversationId. Sendable and
@unchecked so the realtime decode path (an actor) can read
per-chat policy synchronously without awaiting @MainActor. The
@Observable ChatVaultPolicyService resolver lands in Task 5 and
will write through this mirror on every setPolicy / loadPolicy.

Four tests: write+read, unknown lookup returns nil, remove clears,
concurrent writes/reads survive.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `ChatVaultPolicyService` resolver + tests

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Services/ChatVaultPolicyService.swift` (add the resolver above the mirror)
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/ChatVaultPolicyServiceTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/UnitTests/Features/Chats/ChatVaultPolicyServiceTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatVaultPolicyServiceTests: XCTestCase {

    func test_effectivePolicy_returnsDefaultsWhenCacheCold() {
        let service = ChatVaultPolicyService(localDatabase: StubVaultDatabase())
        let policy = service.effectivePolicy(for: "c1")
        XCTAssertEqual(policy, .defaults(for: "c1"))
        XCTAssertNil(service.mirror.policy(for: "c1"))
    }

    func test_loadPolicy_hydratesCacheAndMirror() async {
        let db = StubVaultDatabase()
        db.policies["c1"] = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: true,
            screenshotProtection: false
        )
        let service = ChatVaultPolicyService(localDatabase: db)

        await service.loadPolicy(conversationId: "c1")

        XCTAssertEqual(service.effectivePolicy(for: "c1").autoVaultIncoming, true)
        XCTAssertEqual(service.mirror.policy(for: "c1")?.viewOnceOutgoing, true)
    }

    func test_loadPolicy_isIdempotent() async {
        let db = StubVaultDatabase()
        db.policies["c1"] = .defaults(for: "c1")
        let service = ChatVaultPolicyService(localDatabase: db)

        await service.loadPolicy(conversationId: "c1")
        // Mutate the DB out from under the service. Second load
        // should NOT pick up the change because we already cached.
        db.policies["c1"] = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: false
        )
        await service.loadPolicy(conversationId: "c1")

        XCTAssertFalse(service.effectivePolicy(for: "c1").autoVaultIncoming)
    }

    func test_setPolicy_persistsAndMirrorsAndBumpsVersion() async {
        let db = StubVaultDatabase()
        let service = ChatVaultPolicyService(localDatabase: db)
        let initialVersion = service.changeVersion

        let policy = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: true
        )
        await service.setPolicy(policy)

        XCTAssertEqual(db.policies["c1"], policy)
        XCTAssertEqual(service.effectivePolicy(for: "c1"), policy)
        XCTAssertEqual(service.mirror.policy(for: "c1"), policy)
        XCTAssertEqual(service.changeVersion, initialVersion &+ 1)
    }

    func test_setPolicy_postsNotification() async {
        let service = ChatVaultPolicyService(localDatabase: StubVaultDatabase())
        let expectation = self.expectation(forNotification: .chatVaultPolicyDidChange, object: service)

        await service.setPolicy(.defaults(for: "c1"))

        await fulfillment(of: [expectation], timeout: 1.0)
    }
}

private final class StubVaultDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    var policies: [String: ChatVaultPolicy] = [:]

    func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? {
        policies[conversationId]
    }
    func setVaultPolicy(_ policy: ChatVaultPolicy) async throws {
        policies[policy.conversationId] = policy
    }
    func clearVaultPolicy(conversationId: String) async throws {
        policies.removeValue(forKey: conversationId)
    }

    // Crash-on-call stubs for the rest of the protocol — we don't
    // exercise these in this test.
    func saveMessage(_ message: Message) async throws { fatalError() }
    func saveIncomingMessageAndQueueAck(_ message: Message) async throws { fatalError() }
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { fatalError() }
    func fetchMessageById(_ messageId: String) async throws -> Message? { fatalError() }
    func deleteMessage(id: String) async throws { fatalError() }
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { fatalError() }
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws { fatalError() }
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { fatalError() }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { fatalError() }
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { fatalError() }
    func saveConversation(_ conversation: Conversation) async throws { fatalError() }
    func fetchConversation(id: String) async throws -> Conversation? { fatalError() }
    func fetchConversations() async throws -> [Conversation] { fatalError() }
    func deleteConversation(id: String) async throws { fatalError() }
    func saveContact(_ user: User) async throws { fatalError() }
    func fetchContacts() async throws -> [User] { fatalError() }
    func searchContacts(query: String) async throws -> [User] { fatalError() }
    func saveVaultItem(_ item: VaultItem) async throws { fatalError() }
    func fetchVaultItems() async throws -> [VaultItem] { fatalError() }
    func deleteVaultItem(id: String) async throws { fatalError() }
    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws { fatalError() }
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { fatalError() }
    func deleteAccessKeyEntry(mediaId: String) async throws { fatalError() }
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { fatalError() }
    func deleteAllAccessKeyEntries() async throws { fatalError() }
    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { fatalError() }
    func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws { fatalError() }
    func clearAppearanceOverride(conversationId: String) async throws { fatalError() }
    func hasLocalHistory() async throws -> Bool { fatalError() }
    func exportBackupSnapshot(currentUserId: String?) async throws -> BackupArchiveSnapshot { fatalError() }
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?) async throws { fatalError() }
    func purgeAllData() async throws { fatalError() }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Expected: `cannot find 'ChatVaultPolicyService' in scope`.

- [ ] **Step 3: Add the resolver above the mirror in `ChatVaultPolicyService.swift`**

Open `Shared/Services/ChatVaultPolicyService.swift`. **Above** the existing `ChatVaultPolicyMirror` class, add:

```swift
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
```

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/ChatVaultPolicyServiceTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`. Five tests pass.

- [ ] **Step 5: Build main target**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Shared/Services/ChatVaultPolicyService.swift \
        Tests/UnitTests/Features/Chats/ChatVaultPolicyServiceTests.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): ChatVaultPolicyService @Observable resolver

@MainActor resolver mirroring ChatAppearanceService:
- effectivePolicy(for:) returns the cached policy or defaults.
- loadPolicy(conversationId:) is idempotent; on first call hydrates
  both the cache and the lock-protected mirror.
- setPolicy(_:) persists to the local DB, updates cache + mirror,
  bumps changeVersion, posts .chatVaultPolicyDidChange notification.
- Catches DB write failures via try? and logs; in-memory cache
  still updates so the UI immediately reflects intent.

Five unit tests cover defaults, load + hydrate mirror, idempotency,
mutation persists/mirrors/bumps version, notification post.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Container plumbing + ChatDetailView cache warm

**Files:**
- Modify: `ios/Sanchr-iOS/App/DependencyContainer.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Add `chatVaultPolicy` to `DependencyContainer`**

Find the existing `chatAppearance` lazy var (added in the conversation-info rework). After it, add:

```swift
    /// Per-chat vault media policy resolver. Mirrors the
    /// chatAppearance pattern: @MainActor @Observable resolver +
    /// lock-protected sibling for the realtime decode path.
    @MainActor @ObservationIgnored lazy var chatVaultPolicy: ChatVaultPolicyService = ChatVaultPolicyService(
        localDatabase: localDatabase
    )
```

- [ ] **Step 2: Warm the policy cache in `ChatDetailView.task`**

Find the existing `.task { await container.chatAppearance.loadOverride(conversationId: conversation.id); ... }` block in `Features/Chats/Presentation/ChatDetailView.swift`. Add a parallel warm call right after the appearance one:

```swift
        .task {
            await container.chatAppearance.loadOverride(conversationId: conversation.id)
            await container.chatVaultPolicy.loadPolicy(conversationId: conversation.id)
            await viewModel.loadMessages(
                conversationId: conversation.id,
                messageRepository: container.messageRepository
            )
        }
```

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/DependencyContainer.swift \
        Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): plumb ChatVaultPolicyService through DependencyContainer

DependencyContainer holds ChatVaultPolicyService as a @MainActor
@ObservationIgnored lazy var. ChatDetailView.task warms the policy
cache on entry (alongside the existing chatAppearance warm-up) so
the realtime decode path's mirror lookup hits a populated entry
when subsequent messages arrive.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 2.**

---

## Phase 3 — Wire format + sender side

### Task 7: `MediaAttachment.isViewOnce` field + `SystemEvent` cases

**Files:**
- Modify: `ios/Sanchr-iOS/SanchrShared/Models/Message.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/MediaAttachmentViewOnceCodableTests.swift`

- [ ] **Step 1: Write failing Codable round-trip tests**

```swift
import XCTest
import SanchrShared

final class MediaAttachmentViewOnceCodableTests: XCTestCase {

    func test_encodeAndDecode_isViewOnceTrue_roundTrips() throws {
        let attachment = Message.MediaAttachment(
            url: URL(string: "sanchr-media://abc")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "image/jpeg",
            sizeBytes: 100,
            isViewOnce: true
        )

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(Message.MediaAttachment.self, from: encoded)

        XCTAssertEqual(decoded.isViewOnce, true)
    }

    func test_decodeLegacyJSONWithoutKey_returnsNil() throws {
        let legacyJSON = """
        {
            "url": "sanchr-media://abc",
            "encryptionKey": "AQ==",
            "encryptionIV": "Ag==",
            "mimeType": "image/jpeg",
            "sizeBytes": 100
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Message.MediaAttachment.self, from: legacyJSON)

        XCTAssertNil(decoded.isViewOnce)
    }

    func test_omitsKeyWhenNil() throws {
        let attachment = Message.MediaAttachment(
            url: URL(string: "sanchr-media://abc")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "image/jpeg",
            sizeBytes: 100,
            isViewOnce: nil
        )

        let encoded = try JSONEncoder().encode(attachment)
        let json = String(data: encoded, encoding: .utf8) ?? ""

        // Default JSONEncoder skips nil optionals — verify the key
        // doesn't leak into the wire format.
        XCTAssertFalse(json.contains("isViewOnce"))
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Expected: `extra argument 'isViewOnce' in call`.

- [ ] **Step 3: Add the field to `Message.MediaAttachment`**

Find `public struct MediaAttachment: Codable, Hashable, Sendable {` in `SanchrShared/Models/Message.swift` (around line 55). At the end of the property list (after `audioWaveform`), add:

```swift
        /// View-once flag set by the sender when the per-chat
        /// `viewOnceOutgoing` policy is on. Receiver enforces by
        /// applying ScreenshotProtectionModifier on the gallery and
        /// deleting the local row + cached file on dismiss.
        /// Encoded inside the encrypted envelope — server is blind.
        /// Optional so legacy `Codable` payloads without the key
        /// continue to decode (default nil = standard behavior).
        public var isViewOnce: Bool?
```

In the existing `init(...)` method (around line 86), add the new parameter as the **last** parameter with a nil default so all existing call sites stay unchanged:

```swift
        public init(
            url: URL,
            encryptionKey: Data,
            encryptionIV: Data,
            mimeType: String,
            sizeBytes: Int64,
            thumbnailURL: URL? = nil,
            caption: String? = nil,
            width: Int? = nil,
            height: Int? = nil,
            durationSeconds: Double? = nil,
            blurHash: String? = nil,
            filename: String? = nil,
            isVoiceMessage: Bool? = nil,
            audioDurationMs: Int? = nil,
            audioWaveform: [Float]? = nil,
            isViewOnce: Bool? = nil
        ) {
            self.url = url
            self.encryptionKey = encryptionKey
            self.encryptionIV = encryptionIV
            self.mimeType = mimeType
            self.sizeBytes = sizeBytes
            self.thumbnailURL = thumbnailURL
            self.caption = caption
            self.width = width
            self.height = height
            self.durationSeconds = durationSeconds
            self.blurHash = blurHash
            self.filename = filename
            self.isVoiceMessage = isVoiceMessage
            self.audioDurationMs = audioDurationMs
            self.audioWaveform = audioWaveform
            self.isViewOnce = isViewOnce
        }
```

- [ ] **Step 4: Add the two new `SystemEvent` cases**

Find `public enum SystemEvent: String, Codable, Hashable, Sendable {` in the same file (around line 121). Add the two new cases AFTER `case screenshotDetected`:

```swift
    public enum SystemEvent: String, Codable, Hashable, Sendable {
        case identityKeyChanged
        case disappearingTimerChanged
        case groupCreated
        case memberAdded
        case memberRemoved
        case screenshotDetected
        case viewOnceConsumed
        case autoVaulted
    }
```

- [ ] **Step 5: Run the Codable tests, expect pass**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/MediaAttachmentViewOnceCodableTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Build main target**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add SanchrShared/Models/Message.swift \
        Tests/UnitTests/Features/Chats/MediaAttachmentViewOnceCodableTests.swift && \
git commit -m "$(cat <<'EOF'
feat(shared): add isViewOnce + new SystemEvent cases

MediaAttachment.isViewOnce: Bool? — single optional field encoded
inside the existing E2EE envelope. Optional + nil-default keeps
legacy Codable payloads round-tripping cleanly. JSONEncoder skips
nil optionals so the key doesn't leak into messages from clients
that don't use the per-chat policy.

SystemEvent.viewOnceConsumed and .autoVaulted — two new enum cases
for the tombstones the receiver enforcement path inserts.

Three Codable round-trip tests verify the wire format.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `VaultPolicyResolving` protocol seam + adapters

**Files:**
- Create: `ios/Sanchr-iOS/SanchrShared/Messaging/VaultPolicyResolving.swift`
- Create: `ios/Sanchr-iOS/Shared/Services/MainAppVaultPolicyResolver.swift`
- Create: `ios/Sanchr-iOS/Shared/Services/NoopVaultPolicyResolver.swift`

- [ ] **Step 1: Create the protocol in SanchrShared**

```swift
import Foundation

/// Cross-isolation seam used by the actor-isolated `MessageSender`
/// to read per-chat vault policy without depending on the @MainActor
/// `ChatVaultPolicyService` directly. The main app provides an
/// adapter that hops to @MainActor; the share extension provides a
/// no-op stub because the share extension does not (yet) support
/// per-chat policy customization.
public protocol VaultPolicyResolving: Sendable {
    func policy(for conversationId: String) async -> ChatVaultPolicy
}
```

- [ ] **Step 2: Create the main-app adapter**

```swift
import Foundation
import SanchrShared

/// Main-app `VaultPolicyResolving` adapter. Hops to @MainActor and
/// reads from the shared `ChatVaultPolicyService` instance held by
/// the dependency container.
final class MainAppVaultPolicyResolver: VaultPolicyResolving, @unchecked Sendable {
    private let service: ChatVaultPolicyService

    init(service: ChatVaultPolicyService) {
        self.service = service
    }

    func policy(for conversationId: String) async -> ChatVaultPolicy {
        await MainActor.run {
            service.effectivePolicy(for: conversationId)
        }
    }
}
```

- [ ] **Step 3: Create the share-extension stub**

```swift
import Foundation
import SanchrShared

/// Share-extension `VaultPolicyResolving` stub. Always returns
/// defaults — the share extension does not support per-chat
/// policy customization yet (deferred to a future spec; see
/// docs/superpowers/specs/2026-04-08-vault-media-policy-design.md
/// §9 Out of scope).
struct NoopVaultPolicyResolver: VaultPolicyResolving {
    func policy(for conversationId: String) async -> ChatVaultPolicy {
        .defaults(for: conversationId)
    }
}
```

- [ ] **Step 4: Regenerate project + build**

```bash
/opt/homebrew/bin/xcodegen generate 2>&1 | tail -1
```

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add SanchrShared/Messaging/VaultPolicyResolving.swift \
        Shared/Services/MainAppVaultPolicyResolver.swift \
        Shared/Services/NoopVaultPolicyResolver.swift && \
git commit -m "$(cat <<'EOF'
feat(shared): add VaultPolicyResolving cross-isolation seam

Public protocol in SanchrShared so the actor-isolated MessageSender
can read per-chat vault policy without depending on the @MainActor
ChatVaultPolicyService directly.

Two adapters in the main-app target:
- MainAppVaultPolicyResolver hops to @MainActor and reads from the
  shared service.
- NoopVaultPolicyResolver returns defaults always; used by the
  share extension which doesn't (yet) support per-chat policy.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `MessageSender.sendMedia` stamps `isViewOnce`

**Files:**
- Modify: `ios/Sanchr-iOS/SanchrShared/Messaging/MessageSender.swift`
- Modify: `ios/Sanchr-iOS/App/DependencyContainer.swift`
- Modify: `ios/Sanchr-iOS/SanchrShareExtension/Send/ShareSendCoordinator.swift`
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/MessageSenderTests.swift`

- [ ] **Step 1: Write failing test**

In `Tests/UnitTests/MessageSenderTests.swift`, add a new test method to the existing `MessageSenderTests` class. Find the existing test methods and add:

```swift
    func test_sendMedia_stampsIsViewOnceWhenPolicyIsOn() async throws {
        let resolver = StubVaultPolicyResolver()
        resolver.policyToReturn = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: false,
            viewOnceOutgoing: true,
            screenshotProtection: false
        )
        let (sender, _, _, encryptedSender, _) = makeSender(vaultPolicyResolver: resolver)

        // Issue a media send. The fake encrypted sender records the
        // plaintext payload that was passed to it. Decode the payload
        // and verify the embedded MediaAttachment carries isViewOnce.
        let attachment = Message.MediaAttachment(
            url: URL(string: "file:///tmp/test.jpg")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "image/jpeg",
            sizeBytes: 100
        )
        _ = try? await sender.sendMedia(
            attachment: attachment,
            caption: nil,
            to: "c1",
            progress: { _ in }
        )

        let lastCall = await encryptedSender.lastCall
        XCTAssertNotNil(lastCall, "encryptedSender should have been called")
        let plaintext = try XCTUnwrap(lastCall?.plaintext)
        let content = try JSONDecoder().decode(Message.MessageContent.self, from: plaintext)
        guard case .image(let sentAttachment) = content else {
            XCTFail("Expected .image content"); return
        }
        XCTAssertEqual(sentAttachment.isViewOnce, true)
    }

    func test_sendMedia_omitsIsViewOnceWhenPolicyIsOff() async throws {
        let resolver = StubVaultPolicyResolver()
        resolver.policyToReturn = .defaults(for: "c1")
        let (sender, _, _, encryptedSender, _) = makeSender(vaultPolicyResolver: resolver)

        let attachment = Message.MediaAttachment(
            url: URL(string: "file:///tmp/test.jpg")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "image/jpeg",
            sizeBytes: 100
        )
        _ = try? await sender.sendMedia(
            attachment: attachment,
            caption: nil,
            to: "c1",
            progress: { _ in }
        )

        let lastCall = await encryptedSender.lastCall
        let plaintext = try XCTUnwrap(lastCall?.plaintext)
        let content = try JSONDecoder().decode(Message.MessageContent.self, from: plaintext)
        guard case .image(let sentAttachment) = content else {
            XCTFail("Expected .image content"); return
        }
        XCTAssertNil(sentAttachment.isViewOnce)
    }
```

Add the stub resolver near the bottom of the test file, after the existing fakes:

```swift
final class StubVaultPolicyResolver: VaultPolicyResolving, @unchecked Sendable {
    var policyToReturn: ChatVaultPolicy = .defaults(for: "")
    func policy(for conversationId: String) async -> ChatVaultPolicy {
        policyToReturn
    }
}
```

Update the existing `makeSender` helper signature in the test file to accept an optional `vaultPolicyResolver`:

```swift
private func makeSender(
    db: FakeLocalDatabase = FakeLocalDatabase(),
    uploader: FakeUploader = FakeUploader(),
    encryptedSender: FakeEncryptedSender = FakeEncryptedSender(),
    coordinator: FileCoordinatorLock = FileCoordinatorLock(),
    currentUser: FakeCurrentUser = FakeCurrentUser(id: "me"),
    vaultPolicyResolver: VaultPolicyResolving = StubVaultPolicyResolver()
) -> (MessageSender, FakeLocalDatabase, FakeUploader, FakeEncryptedSender, FakeCurrentUser) {
    let sender = MessageSender(
        db: db,
        uploader: uploader,
        encryptedSender: encryptedSender,
        coordinator: coordinator,
        currentUser: currentUser,
        vaultPolicyResolver: vaultPolicyResolver
    )
    return (sender, db, uploader, encryptedSender, currentUser)
}
```

(Adapt `FakeEncryptedSender.lastCall` if the existing fake exposes recorded calls under a different name. Read the file first to confirm.)

- [ ] **Step 2: Add the dependency to `MessageSender`**

In `SanchrShared/Messaging/MessageSender.swift`, add the new stored property to the dependencies block (around line 161):

```swift
    private let db: LocalDatabaseProtocol
    private let uploader: MediaUploading
    private let encryptedSender: EncryptedMessageSendingClient
    private let coordinator: FileCoordinatorLock
    private let currentUser: CurrentUserProviding
    private let logger: MessageSenderLogging
    private let vaultPolicyResolver: VaultPolicyResolving
```

Update the public init (around line 170):

```swift
    public init(
        db: LocalDatabaseProtocol,
        uploader: MediaUploading,
        encryptedSender: EncryptedMessageSendingClient,
        coordinator: FileCoordinatorLock,
        currentUser: CurrentUserProviding,
        vaultPolicyResolver: VaultPolicyResolving,
        logger: MessageSenderLogging = NoopMessageSenderLogger()
    ) {
        self.db = db
        self.uploader = uploader
        self.encryptedSender = encryptedSender
        self.coordinator = coordinator
        self.currentUser = currentUser
        self.vaultPolicyResolver = vaultPolicyResolver
        self.logger = logger
    }
```

- [ ] **Step 3: Stamp `isViewOnce` in `sendMedia`**

Find the `public func sendMedia(...)` method body. Locate where the `uploadedAttachment` is constructed via `Message.MediaAttachment(url: mediaIdURL, ...)`. **Before** that constructor call, read the policy:

```swift
        let policy = await vaultPolicyResolver.policy(for: chatId)
```

Then add `isViewOnce` to the existing `uploadedAttachment` constructor:

```swift
        var uploadedAttachment = Message.MediaAttachment(
            url: mediaIdURL,
            encryptionKey: uploadOutcome.encryptionKey,
            encryptionIV: uploadOutcome.encryptionNonce,
            mimeType: attachment.mimeType,
            sizeBytes: uploadOutcome.plaintextFileSize,
            thumbnailURL: uploadOutcome.thumbnailRemoteURL.flatMap(URL.init(string:)),
            caption: caption ?? attachment.caption,
            width: attachment.width,
            height: attachment.height,
            durationSeconds: attachment.durationSeconds,
            blurHash: attachment.blurHash,
            filename: attachment.filename,
            isVoiceMessage: attachment.isVoiceMessage,
            audioDurationMs: attachment.audioDurationMs,
            audioWaveform: attachment.audioWaveform,
            isViewOnce: policy.viewOnceOutgoing ? true : nil
        )
```

(If the existing constructor already passes some optional fields by name and others as defaults, adapt — the goal is to add the `isViewOnce` argument at the end.)

- [ ] **Step 4: Update the main-app `messageSender` construction in `DependencyContainer`**

Find where `MessageSender` is constructed in `App/DependencyContainer.swift`. Add the `vaultPolicyResolver` argument:

```swift
    @ObservationIgnored lazy var messageSender = MessageSender(
        db: localDatabase,
        uploader: mediaUploadAdapter,
        encryptedSender: encryptedMessageSendingClient,
        coordinator: fileCoordinatorLock,
        currentUser: currentUserAdapter,
        vaultPolicyResolver: MainAppVaultPolicyResolver(service: chatVaultPolicy),
        logger: senderLogger
    )
```

(Adapt to whatever the existing argument list looks like — read the file first.)

- [ ] **Step 5: Update the share-extension `MessageSender` construction**

Find the `MessageSender(...)` constructor call inside `SanchrShareExtension/Send/ShareSendCoordinator.swift`. Add `vaultPolicyResolver: NoopVaultPolicyResolver()` to the argument list. The share extension can't import `MainAppVaultPolicyResolver` (different target), so the no-op stub is the only choice.

- [ ] **Step 6: Run the new tests, expect pass**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/MessageSenderTests/test_sendMedia_stampsIsViewOnceWhenPolicyIsOn \
  -only-testing:SanchrTests/MessageSenderTests/test_sendMedia_omitsIsViewOnceWhenPolicyIsOff 2>&1 | tail -5
```

Expected: both pass.

- [ ] **Step 7: Build main target**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add SanchrShared/Messaging/MessageSender.swift \
        App/DependencyContainer.swift \
        SanchrShareExtension/Send/ShareSendCoordinator.swift \
        Tests/UnitTests/MessageSenderTests.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): MessageSender stamps isViewOnce per chat policy

MessageSender gains a vaultPolicyResolver dependency. sendMedia
reads the per-chat policy for the target conversation and stamps
isViewOnce on the rebuilt MediaAttachment when viewOnceOutgoing
is true. The flag rides inside the encrypted Message.MessageContent
JSON payload — server stays blind.

Main app constructs MessageSender with MainAppVaultPolicyResolver
(hops to @MainActor and reads from container.chatVaultPolicy).
Share extension uses NoopVaultPolicyResolver — per-chat view-once
respect from the share extension is deferred to a future spec.

Two new MessageSenderTests cases verify on/off paths through the
encrypted-send fake.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 3.**

---

## Phase 4 — Receiver-side enforcement (auto-vault routing)

### Task 10: Auto-vault routing in `MessageRepositoryImpl.decodeMessage`

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift`
- Modify: `ios/Sanchr-iOS/App/DependencyContainer.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/ChatVaultRoutingTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatVaultRoutingTests: XCTestCase {

    func test_isVaultEligible_returnsTrueForMedia() {
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.image(Self.attachment("image/jpeg"))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.video(Self.attachment("video/mp4"))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.audio(Self.attachment("audio/m4a"))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.document(Self.attachment("application/pdf"))))
    }

    func test_isVaultEligible_returnsFalseForText() {
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligibleContent(.text("hi")))
    }

    func test_isVaultEligible_returnsFalseForSystem() {
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligibleContent(.system(.identityKeyChanged)))
    }

    private static func attachment(_ mime: String) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://x")!,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mime,
            sizeBytes: 0
        )
    }
}
```

(The full routing flow involves a real `VaultRepository` upload + replacement — too much for a unit test. We test the eligibility predicate here and rely on the manual smoke matrix in Phase 7 for the integration.)

- [ ] **Step 2: Run tests, expect compile failure**

Expected: `'isVaultEligibleContent' is not a member type of 'MessageRepositoryImpl'`.

- [ ] **Step 3: Add the eligibility helper as a static method**

In `Shared/Repositories/MessageRepository.swift`, add to `MessageRepositoryImpl`:

```swift
    /// Returns true if the message content is something we route into
    /// the vault when the per-chat `autoVaultIncoming` policy is on.
    /// Text and system events stay as normal chat rows.
    static func isVaultEligibleContent(_ content: Message.MessageContent) -> Bool {
        switch content {
        case .image, .video, .audio, .document: return true
        case .text, .location, .contact, .system: return false
        }
    }
```

- [ ] **Step 4: Add `chatVaultPolicyMirror` and `vaultRepository` deps to `MessageRepositoryImpl`**

Update the stored properties + init:

```swift
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let signalProtocol: SignalProtocolManagerProtocol
    private let currentUserIdProvider: @Sendable () -> String?
    private let chatVaultPolicyMirror: ChatVaultPolicyMirror
    private let vaultRepository: VaultRepositoryProtocol
    private let mediaDownloadManager: MediaDownloadManager
    private let streamController = MessageStreamController()

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        signalProtocol: SignalProtocolManagerProtocol,
        chatVaultPolicyMirror: ChatVaultPolicyMirror,
        vaultRepository: VaultRepositoryProtocol,
        mediaDownloadManager: MediaDownloadManager,
        currentUserIdProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.signalProtocol = signalProtocol
        self.chatVaultPolicyMirror = chatVaultPolicyMirror
        self.vaultRepository = vaultRepository
        self.mediaDownloadManager = mediaDownloadManager
        self.currentUserIdProvider = currentUserIdProvider
    }
```

- [ ] **Step 5: Insert the auto-vault routing branch in `decodeMessage`**

Find the existing `decodeMessage` method (around line 486). Locate the line:

```swift
            try? await localDatabase.saveIncomingMessageAndQueueAck(message)
            return message
```

Replace with:

```swift
            try? await localDatabase.saveIncomingMessageAndQueueAck(message)

            // If per-chat policy says auto-vault, kick off a background
            // routing task. Routing runs OFF the decode hot path so we
            // never block the realtime stream on a vault upload. The
            // task succeeds → replaces the row with a `.system(.autoVaulted)`
            // tombstone. Fails → leaves the original row in place.
            let policy = chatVaultPolicyMirror.policy(for: envelope.conversationID)
                ?? .defaults(for: envelope.conversationID)
            if policy.autoVaultIncoming, Self.isVaultEligibleContent(content) {
                Task { [weak self] in
                    await self?.routeIncomingMessageToVault(message)
                }
            }

            return message
```

Then add the new private method anywhere in the same class:

```swift
    /// Background auto-vault routing. Downloads the encrypted media,
    /// uploads to the vault via the existing repository, and on success
    /// replaces the original chat row with a `.system(.autoVaulted)`
    /// tombstone. On failure leaves the original row in place so the
    /// user doesn't lose the media entirely.
    private func routeIncomingMessageToVault(_ message: Message) async {
        guard let attachment = Self.attachmentFromContent(message.content) else { return }
        do {
            // Download + decrypt the media bytes via the existing
            // download manager. Returns the path to the decrypted file
            // on disk.
            let localFile = try await mediaDownloadManager.download(
                messageId: message.id,
                attachment: attachment
            )
            let data = try Data(contentsOf: localFile)
            let vaultType: VaultItem.VaultItemType = {
                switch message.content {
                case .image: return .photo
                case .video: return .video
                case .audio: return .audio
                case .document: return .document
                default: return .document
                }
            }()
            _ = try await vaultRepository.uploadItem(
                data: data,
                name: attachment.filename ?? "vaulted-\(message.id).bin",
                type: vaultType
            )

            // Replace the original chat row with a tombstone.
            let tombstone = Message(
                id: message.id,
                conversationId: message.conversationId,
                senderId: message.senderId,
                timestamp: message.timestamp,
                content: .system(.autoVaulted),
                status: .delivered,
                isOutgoing: false
            )
            try? await localDatabase.deleteMessage(id: message.id)
            try? await localDatabase.saveIncomingMessageAndQueueAck(tombstone)
            SanchrLogger.chat.info("Auto-vaulted message \(message.id.prefix(8))")
        } catch {
            SanchrLogger.chat.error(
                "Auto-vault routing failed for \(message.id.prefix(8)): \(error.localizedDescription) — leaving original row"
            )
        }
    }

    private static func attachmentFromContent(_ content: Message.MessageContent) -> Message.MediaAttachment? {
        switch content {
        case .image(let a), .video(let a), .audio(let a), .document(let a):
            return a
        default:
            return nil
        }
    }
```

(Verify `VaultItem.VaultItemType` actually has `.audio` — if not, fall back to `.document`. Read the model first.)

- [ ] **Step 6: Update `DependencyContainer` to pass the new args into `MessageRepositoryImpl`**

Find the existing `messageRepository` lazy var. Add:

```swift
    @ObservationIgnored lazy var messageRepository: MessageRepositoryProtocol = MessageRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: localDatabase,
        signalProtocol: signalProtocol,
        chatVaultPolicyMirror: chatVaultPolicy.mirror,
        vaultRepository: vaultRepository,
        mediaDownloadManager: mediaDownloadManager,
        currentUserIdProvider: { [weak self] in self?.sessionService.currentUserId }
    )
```

- [ ] **Step 7: Run the unit tests, expect pass**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/ChatVaultRoutingTests 2>&1 | tail -5
```

Expected: three eligibility tests pass.

- [ ] **Step 8: Build main target**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Shared/Repositories/MessageRepository.swift \
        App/DependencyContainer.swift \
        Tests/UnitTests/Features/Chats/ChatVaultRoutingTests.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): auto-vault routing in MessageRepository.decodeMessage

MessageRepositoryImpl gains chatVaultPolicyMirror, vaultRepository,
and mediaDownloadManager dependencies. After saveIncomingMessageAndQueueAck,
decodeMessage reads the per-chat policy from the lock-protected mirror
(no actor hop) and if autoVaultIncoming is true AND content is media-
eligible, kicks off a background Task that:

1. Downloads + decrypts via the existing MediaDownloadManager.
2. Uploads to the vault via the existing VaultRepository.uploadItem.
3. On success: replaces the original chat row with a
   .system(.autoVaulted) tombstone via deleteMessage +
   saveIncomingMessageAndQueueAck.
4. On failure: leaves the original row in place so the user doesn't
   lose the media entirely.

Routing runs OFF the decode hot path so we never block the realtime
stream on a vault upload round-trip.

Three eligibility unit tests cover the .image/.video/.audio/.document
positives and the .text/.system negatives. Full integration covered
by the Phase 7 manual smoke matrix.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 4.**

---

## Phase 5 — Receiver-side enforcement (view-once + screenshot detection)

### Task 11: `MessageRepository.deleteViewOnceMessage` + `sendSystemEvent`

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift`
- Modify: `ios/Sanchr-iOS/SanchrShared/Messaging/MessageSender.swift`
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/TestDoubles.swift` (mock methods)

- [ ] **Step 1: Add the protocol entries**

In `MessageRepositoryProtocol`, after the existing `func sendMessage(...)` line, add:

```swift
    /// Wipes a view-once message after the receiver dismissed the
    /// gallery. Deletes the local file via MediaDownloadManager,
    /// removes the DB row, and inserts a `.system(.viewOnceConsumed)`
    /// tombstone with the same id+timestamp so the bubble shows as
    /// "Viewed". Best-effort server delete is fire-and-forget.
    func deleteViewOnceMessage(messageId: String) async throws

    /// Sends a system event message into a conversation via the
    /// existing encrypted send pipeline. Used by the gallery to
    /// post `.screenshotDetected` back to the original sender when
    /// a screenshot slips through ScreenshotProtectionModifier.
    func sendSystemEvent(_ event: Message.SystemEvent, conversationId: String) async throws
```

- [ ] **Step 2: Implement `deleteViewOnceMessage` in `MessageRepositoryImpl`**

Add the method body. The method needs `mediaDownloadManager` (already added in Task 10):

```swift
    func deleteViewOnceMessage(messageId: String) async throws {
        guard let message = try await localDatabase.fetchMessageById(messageId) else {
            SanchrLogger.chat.warning("deleteViewOnceMessage: no row for \(messageId.prefix(8))")
            return
        }
        guard let attachment = Self.attachmentFromContent(message.content) else {
            return
        }

        // 1. Wipe the cached decrypted file from MediaDownloadManager.
        await mediaDownloadManager.removeCachedFile(messageId: messageId)

        // 2. Delete the local DB row.
        try? await localDatabase.deleteMessage(id: messageId)

        // 3. Insert a tombstone with the same id + timestamp so the
        //    bubble shows as "Viewed" instead of vanishing.
        let tombstone = Message(
            id: messageId,
            conversationId: message.conversationId,
            senderId: message.senderId,
            timestamp: message.timestamp,
            content: .system(.viewOnceConsumed),
            status: .delivered,
            isOutgoing: message.isOutgoing
        )
        try? await localDatabase.saveIncomingMessageAndQueueAck(tombstone)

        // 4. Best-effort server delete (fire-and-forget). Local file
        //    is already gone so failure here is non-fatal.
        var request = Vync_Messaging_DeleteMessageRequest()
        request.messageID = messageId
        request.forEveryone = false
        _ = try? await grpcClient.messagingService.deleteMessage(request)

        SanchrLogger.chat.info("Deleted view-once message \(messageId.prefix(8))")
    }
```

(`mediaDownloadManager.removeCachedFile(messageId:)` doesn't exist today — see Step 4. The `attachment` binding is unused once Step 4 lands but kept here so the future iteration can use it for documentation.)

- [ ] **Step 3: Implement `sendSystemEvent` in `MessageRepositoryImpl`**

```swift
    func sendSystemEvent(_ event: Message.SystemEvent, conversationId: String) async throws {
        SanchrLogger.chat.info("Sending system event \(event.rawValue) to \(conversationId.prefix(8))")
        let plaintext = try JSONEncoder().encode(Message.MessageContent.system(event))

        // Resolve recipient ids the same way the regular send path
        // does — read the local conversation participants.
        let senderId = currentUserIdProvider() ?? ""
        guard let conversation = try await localDatabase.fetchConversation(id: conversationId) else {
            throw AppError.sessionNotEstablished
        }
        let peerIds = conversation.participants
            .map(\.id)
            .filter { $0 != senderId }
        guard !peerIds.isEmpty else { return }

        var deviceMessages: [Vync_Messaging_DeviceMessage] = []
        for peerId in peerIds {
            let perPeer = try await signalProtocol.encryptForAllDevices(
                plaintext: plaintext,
                recipientId: peerId
            )
            deviceMessages.append(contentsOf: perPeer)
        }

        var request = Vync_Messaging_SendMessageRequest()
        request.conversationID = conversationId
        request.deviceMessages = deviceMessages
        request.contentType = "system"
        _ = try await grpcClient.messagingService.sendMessage(request)
    }
```

- [ ] **Step 4: Add `removeCachedFile` to `MediaDownloadManager`**

In `Shared/Services/MediaDownloadManager.swift`, add a new method on the actor:

```swift
    /// Wipes the cached decrypted file for a message. No-op if
    /// the file doesn't exist. Used by `deleteViewOnceMessage`.
    func removeCachedFile(messageId: String) {
        let fm = FileManager.default
        // The cache layout is `<cacheDir>/<messageId>.<ext>`. We don't
        // know the extension here without re-reading the attachment,
        // so glob the directory for any file starting with the
        // messageId prefix and remove all matches.
        guard let entries = try? fm.contentsOfDirectory(atPath: cacheDir.path) else { return }
        for entry in entries where entry.hasPrefix(messageId + ".") {
            try? fm.removeItem(at: cacheDir.appendingPathComponent(entry))
        }
    }
```

- [ ] **Step 5: Add the conformance stubs to mocks**

Update `Tests/UnitTests/TestDoubles.swift` `MockMessageRepository`:

```swift
    private(set) var deleteViewOnceCalls: [String] = []
    func deleteViewOnceMessage(messageId: String) async throws {
        deleteViewOnceCalls.append(messageId)
    }

    private(set) var sentSystemEvents: [(Message.SystemEvent, String)] = []
    func sendSystemEvent(_ event: Message.SystemEvent, conversationId: String) async throws {
        sentSystemEvents.append((event, conversationId))
    }
```

- [ ] **Step 6: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`. If `Vync_Messaging_DeleteMessageRequest` field names differ from what I assumed (`messageID`, `forEveryone`), grep the generated proto to find the actual names and adapt.

- [ ] **Step 7: Commit**

```bash
git add Shared/Repositories/MessageRepository.swift \
        Shared/Services/MediaDownloadManager.swift \
        Tests/UnitTests/TestDoubles.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): deleteViewOnceMessage + sendSystemEvent on MessageRepository

deleteViewOnceMessage(messageId:):
- Reads the row via fetchMessageById, extracts the attachment.
- Wipes the cached decrypted file via new
  MediaDownloadManager.removeCachedFile.
- Deletes the local DB row.
- Inserts a .system(.viewOnceConsumed) tombstone with the same
  id+timestamp so the bubble shows as "Viewed".
- Fire-and-forget server delete (forEveryone: false). Local file
  is already gone so failure is non-fatal.

sendSystemEvent(_:conversationId:):
- Encodes a Message.MessageContent.system(event) JSON payload.
- Resolves peer recipient ids from the local conversation row.
- Encrypts via existing signalProtocol.encryptForAllDevices.
- Sends via existing messagingService.sendMessage with contentType
  "system" so the receiver decode path picks it up as a system bubble.

MockMessageRepository gets recording stubs for both methods so the
gallery integration tests in Task 12 can assert against them.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: `MediaGalleryView` view-once enforcement

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift`

- [ ] **Step 1: Add view-once state + computed property + onDisappear delete**

Open the gallery view file. Find the existing `struct MediaGalleryView: View {` declaration and the `@State` block. Add:

```swift
    @Environment(DependencyContainer.self) private var container
    @State private var openedViewOnceItems: Set<String> = []
    @State private var screenshotToast: String?
```

Find the existing `var body: some View` block. Add a computed property at the same level:

```swift
    /// True if any item in the current presentation is view-once.
    /// We blanket-protect the gallery rather than toggling per-page
    /// because page transitions race the screenshot block.
    private var anyViewOnceVisible: Bool {
        presentation.items.contains { item in
            switch item.message.content {
            case .image(let a), .video(let a):
                return a.isViewOnce == true
            default:
                return false
            }
        }
    }

    /// Whether the per-chat screenshot-protection toggle is on for
    /// the conversation this gallery is showing. Reads the resolver's
    /// in-memory cache via the @MainActor service — fine inside body.
    private var perChatScreenshotProtection: Bool {
        guard let firstItem = presentation.items.first else { return false }
        let conversationId = firstItem.message.conversationId
        return container.chatVaultPolicy.effectivePolicy(for: conversationId).screenshotProtection
    }

    private func conversationId() -> String? {
        presentation.items.first?.message.conversationId
    }
```

- [ ] **Step 2: Apply the screenshot-protection modifier and tracking**

Find the outermost view in `body` (likely a `ZStack`). Chain on:

```swift
        .modifier(ScreenshotProtectionModifier(isActive: anyViewOnceVisible || perChatScreenshotProtection))
        .onChange(of: currentIndex) { _, newIndex in
            if presentation.items.indices.contains(newIndex) {
                let item = presentation.items[newIndex]
                if case .image(let a) = item.message.content, a.isViewOnce == true {
                    openedViewOnceItems.insert(item.id)
                }
                if case .video(let a) = item.message.content, a.isViewOnce == true {
                    openedViewOnceItems.insert(item.id)
                }
            }
        }
        .onAppear {
            // Capture the initial page if it's a view-once item.
            if presentation.items.indices.contains(currentIndex) {
                let item = presentation.items[currentIndex]
                if case .image(let a) = item.message.content, a.isViewOnce == true {
                    openedViewOnceItems.insert(item.id)
                }
                if case .video(let a) = item.message.content, a.isViewOnce == true {
                    openedViewOnceItems.insert(item.id)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification
        )) { _ in
            guard anyViewOnceVisible, let conversationId = conversationId() else { return }
            screenshotToast = "Sender notified"
            Task {
                try? await container.messageRepository.sendSystemEvent(
                    .screenshotDetected,
                    conversationId: conversationId
                )
            }
        }
        .onDisappear {
            // For every view-once item the user actually saw during
            // this gallery session, fire delete-after-view. Each
            // deleteViewOnceMessage call wipes the cached file +
            // local row + inserts a .viewOnceConsumed tombstone.
            let toDelete = openedViewOnceItems
            openedViewOnceItems.removeAll()
            for messageId in toDelete {
                Task { [weak container] in
                    try? await container?.messageRepository.deleteViewOnceMessage(
                        messageId: messageId
                    )
                }
            }
        }
        .overlay(alignment: .top) {
            if let screenshotToast {
                Text(screenshotToast)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 60)
                    .task(id: screenshotToast) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { self.screenshotToast = nil }
                    }
            }
        }
```

(`onChange(of:)` and `onAppear` both populate `openedViewOnceItems` because the initial paint doesn't fire `onChange`. The duplicate logic is intentional — the `Set.insert` is idempotent so re-inserting is a no-op.)

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`. If `ScreenshotProtectionModifier` isn't directly importable here, add `import SanchrShared` (it lives under `Platform/Security/` and is part of the main app target — should be visible without import).

- [ ] **Step 4: Commit**

```bash
git add Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): MediaGalleryView enforces view-once + screenshot policy

Three new behaviors when an item with attachment.isViewOnce == true
appears in the gallery, OR when the per-chat screenshotProtection
policy is on for the chat:

1. ScreenshotProtectionModifier blanket-applied to the whole gallery
   for as long as ANY view-once item or perChatScreenshotProtection
   is true. We don't toggle per-page because page transitions race
   the secure-text-field activation.

2. openedViewOnceItems Set tracks every view-once item the user
   actually paged onto. .onDisappear fires deleteViewOnceMessage
   for each one — wipes the cached file, deletes the row, inserts
   a .viewOnceConsumed tombstone. Set semantics dedupe re-opens.

3. .onReceive(userDidTakeScreenshotNotification) sends a
   .screenshotDetected system event into the conversation via
   MessageRepository.sendSystemEvent and shows a "Sender notified"
   toast on the receiver's gallery for two seconds.

Reads per-chat screenshot policy from container.chatVaultPolicy
via the existing @MainActor service — fine inside body since the
gallery is a SwiftUI view.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 5.**

---

## Phase 6 — Per-chat Vault Media UI + system event labels

### Task 13: Rewrite `VaultMediaView` to bind to the resolver

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ConversationInfoView.swift`

- [ ] **Step 1: Update the navigation site to pass `conversation.id`**

Find the existing navigation destination (around line 110 today):

```swift
        .navigationDestination(isPresented: $showVaultMedia) {
            VaultMediaView()
        }
```

Replace with:

```swift
        .navigationDestination(isPresented: $showVaultMedia) {
            VaultMediaView(conversationId: conversation.id)
        }
```

- [ ] **Step 2: Replace the body of the private `VaultMediaView` struct**

Find the `private struct VaultMediaView: View {` declaration (around line 1463). Replace the entire struct body (from `private struct VaultMediaView: View {` through its closing `}`) with:

```swift
private struct VaultMediaView: View {
    let conversationId: String

    @Environment(DependencyContainer.self) private var container
    @State private var policy: ChatVaultPolicy
    @State private var isLoading: Bool = true

    init(conversationId: String) {
        self.conversationId = conversationId
        self._policy = State(initialValue: .defaults(for: conversationId))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                infoBanner

                vaultToggle(
                    icon: "tray.and.arrow.down.fill",
                    title: "Auto-Vault Incoming",
                    subtitle: "Automatically protect received media in this chat",
                    isOn: Binding(
                        get: { policy.autoVaultIncoming },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: newValue,
                                viewOnceOutgoing: policy.viewOnceOutgoing,
                                screenshotProtection: policy.screenshotProtection
                            )
                            persist()
                        }
                    )
                )

                divider

                vaultToggle(
                    icon: "eye.fill",
                    title: "View Once",
                    subtitle: "Media you send disappears after the recipient views it",
                    isOn: Binding(
                        get: { policy.viewOnceOutgoing },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: policy.autoVaultIncoming,
                                viewOnceOutgoing: newValue,
                                screenshotProtection: policy.screenshotProtection
                            )
                            persist()
                        }
                    )
                )

                divider

                vaultToggle(
                    icon: "camera.metering.none",
                    title: "Screenshot Protection",
                    subtitle: "Block screenshots while viewing vault media",
                    isOn: Binding(
                        get: { policy.screenshotProtection },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: policy.autoVaultIncoming,
                                viewOnceOutgoing: policy.viewOnceOutgoing,
                                screenshotProtection: newValue
                            )
                            persist()
                        }
                    )
                )
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Vault Media")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await container.chatVaultPolicy.loadPolicy(conversationId: conversationId)
            policy = container.chatVaultPolicy.effectivePolicy(for: conversationId)
            isLoading = false
        }
    }

    private func persist() {
        Task {
            await container.chatVaultPolicy.setPolicy(policy)
        }
    }

    @ViewBuilder
    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SanchrColors.primaryDark)
                .padding(.top, 2)
            Text(
                "Vault media is encrypted at rest, can self-destruct after viewing, and screenshots are blocked while viewing."
            )
            .font(SanchrTypography.messageBubbleText)
            .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    SanchrColors.primaryDark.opacity(0.05),
                    SanchrColors.primary.opacity(0.05),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var divider: some View {
        Rectangle()
            .fill(SanchrExportColors.line)
            .frame(height: 1)
            .padding(.leading, 72)
    }

    private func vaultToggle(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceSoft)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
```

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Features/Chats/Presentation/ConversationInfoView.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): rewrite per-chat VaultMediaView for real persistence

VaultMediaView used to hold three @State Bool toggles that nothing
read or persisted. Replaced with a real picker bound to
ChatVaultPolicyService:

- init(conversationId:) — single nav site updated to pass
  conversation.id.
- @State policy hydrated on .task via loadPolicy +
  effectivePolicy(for:).
- Three toggles bound via Binding<Bool> wrappers that immutably
  rebuild ChatVaultPolicy and call container.chatVaultPolicy.setPolicy.
- Sharper subtitle copy (per-chat scope explicit on every toggle).
- Same three-row layout, info banner copy updated.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: System event label rendering for new cases

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Add the two new cases to `MessageBubble.systemEventLabel`**

Find `private func systemEventLabel(_ event: Message.SystemEvent) -> String {` (around line 1213). Add the two new cases:

```swift
    private func systemEventLabel(_ event: Message.SystemEvent) -> String {
        switch event {
        case .identityKeyChanged: return "Security code changed"
        case .disappearingTimerChanged: return "Disappearing timer changed"
        case .groupCreated: return "Group created"
        case .memberAdded: return "Member added"
        case .memberRemoved: return "Member removed"
        case .screenshotDetected: return "Screenshot detected"
        case .viewOnceConsumed: return "Viewed"
        case .autoVaulted: return "Auto-vaulted media"
        }
    }
```

- [ ] **Step 2: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`. If the compiler complains that the switch is non-exhaustive, that means the existing switch is missing cases and a `default:` was relied on — adapt by adding to the existing default branch.

- [ ] **Step 3: Commit**

```bash
git add Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): render new SystemEvent cases in MessageBubble

systemEventLabel handles:
- .viewOnceConsumed → "Viewed" (the tombstone left after a
  view-once message has been deleted on dismiss).
- .autoVaulted → "Auto-vaulted media" (the placeholder inserted
  when an incoming media message is routed to the vault by the
  per-chat policy).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 6.**

---

## Phase 7 — Final verification + smoke matrix

### Task 15: Build, test suite, smoke matrix

**Files:** none — verification only.

- [ ] **Step 1: Run the standard build verification command**

Expected: `** BUILD SUCCEEDED **`. Any failure → back to the offending phase.

- [ ] **Step 2: Run the full unit test suite**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. The new test files (`ChatVaultPolicyMirrorTests`, `ChatVaultPolicyServiceTests`, `MediaAttachmentViewOnceCodableTests`, `MessageSenderViewOnceTests`, `ChatVaultRoutingTests`) run via the SanchrTests scheme. Pre-existing simulator-NIO break may still apply — confirm it's the same break, not a new one introduced by this work.

- [ ] **Step 3: Manual smoke matrix on a real device or arm64 sim**

| # | Action | Expected |
|---|---|---|
| 1 | Open Conversation Info → Vault Media | Three toggles, all off, scope is "this chat" |
| 2 | Toggle Auto-Vault Incoming on, force-quit, reopen | Toggle persists |
| 3 | Send a photo from another device to this chat | Message becomes a "Auto-vaulted media" system bubble; the photo appears in the existing Vault tab |
| 4 | Toggle Auto-Vault Incoming off, send another photo | Photo arrives as a normal bubble |
| 5 | Toggle View Once on, send a photo from this chat | Recipient sees a normal bubble; tapping it opens the gallery; on dismiss the bubble flips to "Viewed" |
| 6 | Open the View Once item on the recipient device, dismiss without screenshotting | Bubble flips to "Viewed", local cache wiped; trying to re-tap shows the tombstone only |
| 7 | Open the View Once item on the recipient device, take a screenshot | Screenshot is blanked (secure-text-field protection); a "Screenshot detected" system bubble appears in the original sender's chat |
| 8 | Toggle Screenshot Protection on for the chat (with View Once off), open any media in the gallery | Secure-text-field protection is active for as long as the gallery is open |
| 9 | Toggle all three on, sync settings across launches | All three toggles persist via the v5 migration |
| 10 | Logout / delete account | `purgeAllData()` cascades the new `chatVaultPolicy` table; reinstall starts clean |
| 11 | Send a non-view-once photo, open it in the gallery, dismiss | No tombstone, no delete, normal behavior unchanged |
| 12 | Receive a media message in a chat that has Auto-Vault on but the chat has not been opened yet (cold cache) | Message arrives as a normal bubble. Open the chat. From this point on, new messages route correctly. (Documented behavior — the cache warms on chat enter.) |

- [ ] **Step 4: Commit any fixes**

If any rows fail, fix them in targeted commits:

```bash
git add <fixed files>
git commit -m "fix(chats): <specific fix>"
```

- [ ] **Step 5: Final milestone commit**

```bash
git commit --allow-empty -m "chore: per-chat vault media policy feature complete"
```

---

## Out of scope (not in this plan)

- Server-side view-once enforcement or TTL.
- Group chats. Spec assumes 1:1.
- Auto-vault for outgoing messages.
- Replay window or countdown timer for view-once.
- Unwinding auto-vault history.
- Share-extension respect for per-chat view-once policy.
- Screenshot detection across external devices (camera-pointed-at-screen, screen mirroring).
- Vault item shareability check for auto-vaulted items.
- Liquid Glass APIs the user has added.
