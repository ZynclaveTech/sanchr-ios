# Per-Chat Vault Media Policy — Design Spec

**Date:** 2026-04-08
**Status:** Approved for planning
**Scope:** iOS client only. New SQLCipher table. **No backend, proto, or server changes.**

## 1. Problem

The "Vault Media" row in `ConversationInfoView` opens a `WallpaperThemeView`-style placeholder screen with three toggles — Auto-Vault Incoming, View Once, Screenshot Protection — that today are bound to local `@State` and persist nothing, enforce nothing, and propagate nothing. The user has zero ability to set per-chat vault behavior.

Three intertwined behaviors need to land together so the toggles are honest:

1. **Auto-Vault Incoming** — when ON for a chat, every received media message (image / video / audio / document) is routed into the existing Vault subsystem at decrypt time instead of becoming a regular chat bubble.
2. **View Once** — when ON for a chat, every outgoing media message gets a `view_once` flag inside the encrypted envelope. The receiver's gallery applies `ScreenshotProtectionModifier` while the item is on screen, deletes the local row + cached file on dismiss, and replaces the bubble with a tombstone.
3. **Screenshot Protection** — when ON for a chat, the receiver's gallery applies `ScreenshotProtectionModifier` while any vault media for this chat is open, regardless of view-once. If iOS still fires `userDidTakeScreenshotNotification` (e.g. external recording, future bypass), the receiver sends a `screenshotDetected` system event back into the conversation so the sender sees an inline warning bubble.

## 2. Goals

1. Three toggles in `VaultMediaView` actually persist per-chat, enforce per-chat, and propagate per-chat.
2. **Zero proto / backend changes.** Everything rides inside the existing E2EE message envelope or as a local-only routing decision. The metadata-privacy plan stays whole.
3. Per-chat policy storage uses the same sibling-table pattern as `chatAppearanceOverride`, with cascade-on-delete via FK to `conversation`.
4. Reuses the existing `MediaGalleryView` from the bubble-viewers feature for view-once viewing — no new full-screen viewer.
5. Reuses the existing `Vault` subsystem (`VaultDataSource`, `VaultUseCases.CreateVaultItem`) for auto-vault routing — no new vault storage code.
6. Reuses `ScreenshotProtectionModifier` from `Platform/Security/` — no new screenshot-blocking machinery.
7. Existing `Message.SystemEvent.screenshotDetected` enum case is wired through. Two new cases (`viewOnceConsumed`, `autoVaulted`) are added for the new tombstones.
8. Liquid Glass APIs the user added remain untouched.

## 3. Non-Goals

- Server-enforced view-once or TTL. Server stays a dumb encrypted blob store.
- Backend / proto changes of any kind.
- Group chats. The whole spec assumes 1:1 conversations.
- Auto-vault for **outgoing** messages.
- Custom view-once countdown timer (Snapchat style).
- Replay window — view-once means strictly one open.
- Unwinding auto-vault (toggling off does NOT restore previously-vaulted history).
- Share-extension respect for per-chat view-once policy. Share extension uses a no-op resolver and always sends non-view-once media until a future spec wires the App Group.
- Screenshot detection across external devices (camera pointed at screen, screen mirroring). Best-effort by definition, like every other messenger's view-once.
- Touching any view that uses Liquid Glass APIs added by the user.

## 4. Architecture

Three layers, each isolated, each a small change to an existing seam.

### 4.1 Data model

**New SQLCipher migration `v5_chat_vault_policy`:**

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

Sibling table — keeps `ConversationRecord` untouched, cascades on conversation delete, matches the `chatAppearanceOverride` precedent.

**New value type `SanchrShared/Models/ChatVaultPolicy.swift`:**

```swift
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

**`ChatVaultPolicyRecord`** in `SanchrShared/Persistence/DatabaseRecords.swift` — GRDB Codable+PersistableRecord, mirrors `ChatAppearanceOverrideRecord` shape exactly.

**`LocalDatabaseProtocol` additions:**

```swift
func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy?
func setVaultPolicy(_ policy: ChatVaultPolicy) async throws
func clearVaultPolicy(conversationId: String) async throws
```

### 4.2 `ChatVaultPolicyService` resolver

**New file:** `Shared/Services/ChatVaultPolicyService.swift`. Mirrors `ChatAppearanceService` exactly — single source of truth, `@Observable @MainActor`, cache + load + set + notification.

```swift
@Observable
@MainActor
final class ChatVaultPolicyService {
    var changeVersion: UInt64 = 0
    private var cache: [String: ChatVaultPolicy] = [:]
    private var loadedConversationIds: Set<String> = []
    private let localDatabase: LocalDatabaseProtocol

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
            SanchrLogger.chat.error("ChatVaultPolicy.setPolicy DB write failed: \(error.localizedDescription)")
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

    /// Locked mirror exposed to the background realtime decrypt path.
    /// Updated by `setPolicy` and `loadPolicy` (both @MainActor) and
    /// read by the realtime service via `mirror.policy(for:)` without
    /// any actor hop. See `ChatVaultPolicyMirror` below.
    let mirror = ChatVaultPolicyMirror()
}

/// Lock-protected mirror of `ChatVaultPolicyService.cache` so the
/// background message-handling path (`RealtimeMessagingService`) can
/// read per-chat policy synchronously without awaiting the @MainActor
/// resolver. Same precedent as `MediaDownloadManager`'s `inFlight`
/// dictionary, which is also a thread-safe accessor across actor
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

extension Notification.Name {
    static let chatVaultPolicyDidChange = Notification.Name("sanchr.chatVaultPolicyDidChange")
}
```

**Lifetime:** `lazy var chatVaultPolicy` on `DependencyContainer`, single instance for the app's lifetime. `ChatDetailView.task` warms it via `loadPolicy(conversationId:)` alongside the existing appearance warm-up so the realtime receive path can read the policy synchronously without async hops.

**Note on `cachedPolicy(for:) nonisolated`:** the realtime receive path runs on a background actor and cannot `await` a `@MainActor` method per message without serializing the whole stream through main. The sketch above is a placeholder; the implementation plan introduces a small `NSLock`-protected mirror dictionary that the `@MainActor` setters update and the `nonisolated` getter reads. Same pattern as `MediaDownloadManager.inFlight`. Documented in the plan.

### 4.3 Wire format & sender side

**Single new field on `Message.MediaAttachment`** in `SanchrShared/Models/Message.swift`:

```swift
public var isViewOnce: Bool?
```

Optional with nil default so the `Codable` decode of older messages stays compatible. The `init` gains `isViewOnce: Bool? = nil` as the last parameter; every existing call site stays unchanged.

**Sender path: `MessageSender.sendMedia`** at `SanchrShared/Messaging/MessageSender.swift`:

Adds a single policy lookup before constructing the rebuilt `MediaAttachment`. The rebuilt attachment carries `isViewOnce: policy.viewOnceOutgoing ? true : nil`. Server is blind because the attachment is JSON-encoded into `Message.MessageContent`, then encrypted into the envelope.

**`VaultPolicyResolving` protocol seam** lives in `SanchrShared/Messaging/`. `MessageSender` (an actor) holds a `VaultPolicyResolving` dependency rather than the `@MainActor ChatVaultPolicyService` directly:

```swift
public protocol VaultPolicyResolving: Sendable {
    func policy(for conversationId: String) async -> ChatVaultPolicy
}
```

Two adapters:

- **Main app** — `MainAppVaultPolicyResolver` hops to `@MainActor` and calls `chatVaultPolicy.effectivePolicy(for:)`.
- **Share extension** — `NoopVaultPolicyResolver` returns `.defaults(...)` always. The share extension does not honor per-chat view-once until a future spec wires the App Group.

Both adapters live in the main app target (`Shared/Services/`) and are constructed by `DependencyContainer.messageSender` and `ShareSendCoordinator` respectively.

**No proto changes. No new RPCs. No new server fields.**

### 4.4 Receiver-side enforcement

Three independent enforcement points, each isolated.

#### 4.4.a Auto-vault routing on incoming messages

**Location:** the existing message-decrypt-and-persist path. The exact file depends on the realtime architecture:

```bash
grep -rn "saveIncomingMessageAndQueueAck" Shared/ --include="*.swift"
```

Whichever function calls `localDatabase.saveIncomingMessageAndQueueAck(message)` after decrypting an incoming message gets a new decision point inserted **before** the save:

```swift
let policy = chatVaultPolicy.mirror.policy(for: message.conversationId)
    ?? .defaults(for: message.conversationId)

if policy.autoVaultIncoming, Self.isVaultEligible(message.content) {
    await routeToVault(message)
    return
}

// Existing path:
try? await localDatabase.saveIncomingMessageAndQueueAck(message)
```

`chatVaultPolicy.mirror` is a `Sendable` lock-protected struct (see §4.2) — no actor hop needed. The realtime service holds a reference to the mirror, not the @MainActor resolver, so its hot loop never blocks on main.

**`isVaultEligible`** matches `.image / .video / .audio / .document`. Text and system events are not vaultable.

**`routeToVault(_ message: Message)`** does:

1. Extract `MediaAttachment` from `message.content`.
2. Call the existing `VaultUseCases.CreateVaultItem.execute(...)` with the attachment + sender id + receivedAt.
3. If success: insert a placeholder system event row with the same id+timestamp into the chat — `Message.MessageContent.system(.autoVaulted)`. The chat shows an "Auto-vaulted media from <sender>" bubble instead of going silent.
4. If failure: log and fall through to the normal `saveIncomingMessageAndQueueAck` so the user doesn't lose the message entirely.

**`CreateVaultItem` reuse:** the existing use case at `Features/Vault/Domain/VaultUseCases.swift` is constructed today by `Features/Vault/Presentation/VaultViewModel.swift` and hits `VaultDataSource.createVaultItem` which uploads + persists via `localDatabase.saveVaultItem`. The realtime path needs the same use case wired through `DependencyContainer`. If `DependencyContainer` doesn't already vend a `CreateVaultItem` use case, add one.

#### 4.4.b View-once gallery + delete-on-dismiss

**Location:** `Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift` from the bubble-viewers feature.

The gallery container gains:

- An `@State openedViewOnceItems: Set<String>` populated as the user pages onto each view-once item.
- An `anyViewOnceVisible: Bool` computed property that scans `presentation.items` for any `attachment.isViewOnce == true`.
- A `.modifier(ScreenshotProtectionModifier(isActive: anyViewOnceVisible || perChatScreenshotProtection))` that pulls from the `chatVaultPolicy` for the current conversation. The gallery already takes a `presentation` containing message ids; it can read `effectivePolicy(for:)` for the conversation by accessing `container.chatVaultPolicy`.
- An `.onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification))` that fires `postScreenshotSystemEvent()` and `screenshotDetected = true` when `anyViewOnceVisible` is true.
- An `.onDisappear` that for every `messageId in openedViewOnceItems` calls `await container.messageRepository.deleteViewOnceMessage(messageId:)`.

**Note:** the gallery is currently used by both `ChatDetailView` (bubble taps) and `ConversationInfoView` (recent media grid + Shared Content). Both use sites need to provide the conversation id so the gallery can resolve the policy. The gallery's existing `presentation` already carries `items: [GalleryItem]` where `GalleryItem.message.conversationId` is available — no new parameter needed.

#### 4.4.c Screenshot detection → system event

When `userDidTakeScreenshotNotification` fires inside the gallery while `anyViewOnceVisible` is true:

1. Gallery calls `MessageRepository.sendSystemEvent(.screenshotDetected, conversationId:)`.
2. Marks the currently-visible view-once item as already-consumed in `openedViewOnceItems` so the dismiss-time delete fires.
3. Shows a brief toast "Sender notified" inside the gallery.

**`MessageRepository.sendSystemEvent(_:conversationId:)`** is a new method on `MessageRepositoryProtocol`:

```swift
func sendSystemEvent(_ event: Message.SystemEvent, conversationId: String) async throws
```

Wraps the existing send pipeline. The system event is encoded as `Message.MessageContent.system(event)` which already has Codable support. The encrypted send client is the same one that handles text — there's no upload step. Add a parallel `MessageSender.sendSystemEvent(...)` actor method that calls `encryptedSender.sendEncryptedMessage(plaintext:contentType: "system", conversationId:, recipientIds:, expiresAfterSecs: 0)` directly without the upload + write-pending-row dance.

#### 4.4.d `MessageRepository.deleteViewOnceMessage`

New method on `MessageRepositoryProtocol`:

```swift
func deleteViewOnceMessage(messageId: String) async throws
```

Implementation:

1. Read the message from `LocalDatabase.fetchMessageById(...)` — if there's no such method today, add one. Returns `nil` for unknown messageIds; method is a no-op in that case.
2. Extract `MediaAttachment` from `message.content`. Skip if none.
3. Wipe the `MediaDownloadManager` cache entry for this message id (remove the file at `cacheDir/<messageId>.<ext>`).
4. Wipe the `ChatMediaResolver` display-name link directory at `<tmp>/sanchr-quicklook/<messageId>/` if present.
5. Delete the local DB row via `LocalDatabase.deleteMessage(id:)`.
6. Insert a tombstone row with the same id+timestamp+conversationId, content `.system(.viewOnceConsumed)`. The bubble shows as "Viewed".
7. Best-effort fire-and-forget `messagingService.deleteMessage(...)` to the server with `forEveryone: false` so the server purges its copy. Ignore failures — the local file is already gone.

#### 4.4.e `SystemEvent` enum additions

`SanchrShared/Models/Message.swift`:

```swift
public enum SystemEvent: String, Codable, Hashable, Sendable {
    case identityKeyChanged
    case disappearingTimerChanged
    case groupCreated
    case memberAdded
    case memberRemoved
    case screenshotDetected
    case viewOnceConsumed   // new
    case autoVaulted        // new
}
```

`MessageBubble.systemEventLabel(_:)` in `Features/Chats/Presentation/ChatDetailView.swift` (line ~1213 today) gets two new cases:

```swift
case .viewOnceConsumed: return "Viewed"
case .autoVaulted:      return "Auto-vaulted media"
```

**Forward-compat caveat:** because `SystemEvent` is a `String` rawValue Codable, an older client decoding a future case will fail `init?(rawValue:)` and the JSON decoder will fail the entire `.system` payload decode. Need to verify in the implementation plan that the message decode path falls through to "unknown" rather than crashing. If it crashes today, the plan adds a `default: case .identityKeyChanged` fallback as part of Phase 1.

### 4.5 Per-chat Vault Media UI

**`VaultMediaView`** (private struct in `ConversationInfoView.swift`) gets rewritten:

- `init(conversationId: String)` instead of `init()`. Single nav site updated to pass `conversation.id`.
- Three `@State`-bound toggles backed by an in-memory `ChatVaultPolicy` state that loads from `container.chatVaultPolicy.effectivePolicy(for:)` on `.task` and writes through `container.chatVaultPolicy.setPolicy(_:)` on every change.
- Subtitle copy updated for clarity:
  - "Auto-Vault Incoming" → "Automatically protect received media **in this chat**"
  - "View Once" → "Media **you send** disappears after the recipient views it"
  - "Screenshot Protection" → "Block screenshots while viewing **vault media**"
- No global vs per-chat scope banner — vault policy is per-chat only, no merge with global.
- No loading-state UI — toggles default to off, the `.task` resolves quickly, the binding setter fires the `changeVersion` + notification path.

## 5. Error handling

| Failure | Handling |
|---|---|
| `fetchVaultPolicy` throws / returns nil | Treat as "no policy" → defaults (all toggles off). No alert. |
| `setVaultPolicy` throws | Swallow with `try?`, log via `SanchrLogger.chat.error`. In-memory cache still updates so the UI immediately reflects intent; persistence retries on next mutation. |
| `routeToVault` throws (network, vault upload, etc.) | Fall through to normal `saveIncomingMessageAndQueueAck` so the message isn't lost. Logged. |
| `MessageSender.sendMedia` cannot reach a real `vaultPolicyResolver` (share extension stub) | Outgoing message is sent without `isViewOnce`. Documented behavior. |
| `deleteViewOnceMessage` fails to wipe local file or DB row | Log and continue. Tombstone insert is best-effort. Force-quit + reopen rebuilds from persisted state. |
| `sendSystemEvent` for screenshot detection fails | Silent. The receiver still saw a "Sender notified" toast but the sender doesn't get the system bubble. No retry — screenshot events are time-sensitive and a delayed notification is confusing. |
| Screenshot detected on a non-view-once gallery item | Notification ignored. `anyViewOnceVisible` gates the post. |
| Unknown future `SystemEvent` rawValue arrives | Implementation plan verifies that `Message.MessageContent.system` decode falls through to drop rather than crash. Adds a fallback case if needed in Phase 1. |
| Cache cold (chat opened for the first time, message arrives before warm) | `cachedPolicy` returns nil → defaults → no auto-vault for THIS message. View-once flag inside the encrypted attachment is still respected because the gallery reads `attachment.isViewOnce` directly, independent of the policy. Subsequent messages route correctly after `ChatDetailView.task` warms the cache. |

## 6. Files touched

### New files

| Path | Responsibility |
|---|---|
| `SanchrShared/Models/ChatVaultPolicy.swift` | Value type + defaults factory |
| `Shared/Services/ChatVaultPolicyService.swift` | `@Observable` resolver with cache + load + set + notification |
| `SanchrShared/Messaging/VaultPolicyResolving.swift` | Cross-isolation protocol seam for `MessageSender` |
| `Shared/Services/MainAppVaultPolicyResolver.swift` | Adapter that hops to `@MainActor` and calls the resolver |
| `Tests/UnitTests/Features/Chats/ChatVaultPolicyServiceTests.swift` | Cache + load + set + notification + idempotency |
| `Tests/UnitTests/Features/Chats/ChatVaultRoutingTests.swift` | Auto-vault routing with policy variants |

### Modified files

| Path | Change |
|---|---|
| `SanchrShared/Persistence/DatabaseSchema.swift` | Register `v5_chat_vault_policy` migration |
| `SanchrShared/Persistence/DatabaseRecords.swift` | New `ChatVaultPolicyRecord` |
| `SanchrShared/Persistence/LocalDatabase.swift` | New `fetchVaultPolicy` / `setVaultPolicy` / `clearVaultPolicy` methods + protocol entries + failing-mock + `fetchMessageById` if not present |
| `SanchrShared/Models/Message.swift` | `MediaAttachment.isViewOnce: Bool?` field; `SystemEvent` adds `.viewOnceConsumed` and `.autoVaulted` |
| `SanchrShared/Messaging/MessageSender.swift` | `sendMedia` reads vault policy via `vaultPolicyResolver` and stamps `isViewOnce` on the rebuilt attachment; new `sendSystemEvent` actor method |
| `SanchrShared/Messaging/EncryptedMessageSendingClient.swift` | (Possibly nothing — depends on whether `.system` content type already routes through the existing `sendEncryptedMessage(plaintext:contentType:...)`) |
| `App/DependencyContainer.swift` | Expose `chatVaultPolicy: ChatVaultPolicyService` and `vaultPolicyResolver: VaultPolicyResolving`; ensure `CreateVaultItem` use case is available to the realtime path |
| `Shared/Repositories/MessageRepository.swift` | New `deleteViewOnceMessage(messageId:)` and `sendSystemEvent(_:conversationId:)` methods + protocol entries |
| `Shared/Services/RealtimeMessagingService.swift` (or wherever `saveIncomingMessageAndQueueAck` is called) | Insert auto-vault routing decision before the save |
| `Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift` | View-once enforcement: `anyViewOnceVisible` gating, `ScreenshotProtectionModifier`, `userDidTakeScreenshotNotification` listener, `openedViewOnceItems` tracking, `.onDisappear` delete |
| `Features/Chats/Presentation/ChatDetailView.swift` | `MessageBubble.systemEventLabel(_:)` adds `.viewOnceConsumed` + `.autoVaulted`. `ChatDetailView.task` warms `chatVaultPolicy.loadPolicy(conversationId:)` |
| `Features/Chats/Presentation/ConversationInfoView.swift` | `VaultMediaView` rewrite; `init(conversationId:)`; nav site update |
| `Tests/UnitTests/MessageSenderTests.swift` (FakeLocalDatabase + new test cases) | Mock vault policy resolver + view-once stamping tests |
| `Tests/UnitTests/TestDoubles.swift` | New mocks for `LocalDatabase` vault policy methods |
| `SanchrShareExtension/Send/ShareSendCoordinator.swift` | Inject `NoopVaultPolicyResolver` so the share extension's `MessageSender` instance compiles against the new dependency |

### Files explicitly NOT touched

- Any `.proto` file. No backend changes.
- `VerifySecurityCodeView`, `WallpaperPainter`, `ChatAppearanceService` and any of the Phase-3-of-conversation-info code.
- Any view that already uses Liquid Glass APIs the user has added.
- The existing `Features/Vault/Presentation/VaultView.swift` browsing surface — auto-vaulted items appear there unchanged.

## 7. Testing

**Unit tests** (no UIKit required):

- **`ChatVaultPolicyServiceTests`** mirroring `ChatAppearanceServiceTests`:
  - Default policy returned when no row exists.
  - `setPolicy` persists, updates cache, bumps `changeVersion`, posts notification.
  - `loadPolicy` is idempotent (second call doesn't re-hit DB).
  - `cachedPolicy(for:)` returns nil for unwarmed conversation.
  - `cachedPolicy(for:)` returns the policy after `loadPolicy` even when called from a non-`@MainActor` context (verifies the locked mirror).

- **`MessageSenderViewOnceTests`** extension to `MessageSenderTests.swift`:
  - When `vaultPolicyResolver.policy.viewOnceOutgoing == false`, outgoing `MediaAttachment.isViewOnce` is nil.
  - When `viewOnceOutgoing == true`, outgoing `MediaAttachment.isViewOnce == true`.
  - Round-trip: encode `MediaAttachment(isViewOnce: true)` to JSON, decode back, the field survives.
  - Round-trip: decode legacy JSON without the `isViewOnce` key — the new field is nil.

- **`ChatVaultRoutingTests`** for the realtime auto-vault path:
  - With `autoVaultIncoming == false`, incoming `.image` saves as a normal message via `saveIncomingMessageAndQueueAck`.
  - With `autoVaultIncoming == true`, incoming `.image` triggers `CreateVaultItem.execute` and inserts a `.system(.autoVaulted)` placeholder.
  - With `autoVaultIncoming == true`, incoming `.text` saves as a normal message (text is not vault-eligible).
  - `CreateVaultItem` failure falls through to normal save.

**Manual smoke matrix** in Phase 7 of the implementation plan:

| # | Action | Expected |
|---|---|---|
| 1 | Open Conversation Info → Vault Media | Three toggles, all off, scope is "this chat" |
| 2 | Toggle Auto-Vault Incoming on, force-quit, reopen | Toggle persists |
| 3 | Send a photo from another device to this chat | Message becomes a "🔒 Auto-vaulted media" system bubble; the photo appears in the existing Vault tab |
| 4 | Toggle Auto-Vault Incoming off, send another photo | Photo arrives as a normal bubble |
| 5 | Toggle View Once on, send a photo from this chat | The recipient (other device) sees a normal bubble; tapping it opens the gallery; on dismiss the bubble flips to "Viewed" |
| 6 | Open the View Once item on the recipient device, dismiss without screenshotting | Bubble flips to "Viewed", local cache wiped; trying to re-tap shows the tombstone only |
| 7 | Open the View Once item on the recipient device, take a screenshot | Screenshot is blanked (secure-text-field protection); a "Screenshot detected" system bubble appears in the original sender's chat |
| 8 | Toggle Screenshot Protection on for the chat (with View Once off), open any vault media in the gallery | Secure-text-field protection is active for as long as the gallery is open |
| 9 | Toggle all three on, sync settings across launches | All persisted via the v5 migration |
| 10 | Logout / delete account | `purgeAllData()` cascades the new `chatVaultPolicy` table; reinstall starts clean |

## 8. Rollout

Single phase. Per-chat vault policy is gated on the new `v5_chat_vault_policy` SQLCipher migration which runs on next launch (mandatory, no opt-in). All other changes are pure code edits that take effect on first launch of the new build for every existing user. No feature flag.

## 9. Out of scope / future

- Server-side view-once enforcement or TTL.
- Group chats. The whole spec assumes 1:1.
- Auto-vault for outgoing messages.
- Replay window or countdown timer for view-once.
- Unwinding auto-vault history.
- Share-extension respecting per-chat view-once.
- Screenshot detection for external recording / camera-pointed-at-screen.
- Vault-item shareability check for auto-vaulted items (the existing `ShareVaultItem` use case still works for items the user manually vaulted from the picker; auto-vaulted items aren't restricted from sharing because there's no clear policy yet).
- Liquid Glass APIs the user added.

## 10. Open questions

None. All resolved during brainstorming:

- Q1 — Scope = one big plan
- Q2 — Enforcement = client-side only, no server policy
- Q3 — View-once UX = open + dismiss-to-delete (not countdown)
- Q4 — Auto-vault scope = media only (image/video/audio/document), text passes through
- Q5 — Screenshot protection scope = vault media viewer only (not whole chat)
- Q6 — Screenshot detected → silent system event in the chat (existing `Message.SystemEvent.screenshotDetected` enum case)
