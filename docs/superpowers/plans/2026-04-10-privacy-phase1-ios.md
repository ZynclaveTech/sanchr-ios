# Privacy Phase 1 iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the iOS Privacy screen and Sanchr Mode enforcement: extract a testable `MessagingPrivacyGate` struct that `MessageRepositoryImpl` consults before dispatching read receipts / typing / presence, clear the privacy cache on logout, remove dead UI state, fix dark theme, and delete the extra card borders.

**Architecture:** A new `MessagingPrivacyGate` value type owns the three-way decision logic (`.readReceipt` / `.typingIndicator` / `.presenceHeartbeat` → `.allow` / `.suppress`) over a `PrivacySettingsCache`. `MessageRepositoryImpl` holds an instance and consults it from `markAsRead`, `sendTypingIndicator`, and `sendPresenceHeartbeat`, becoming the single chokepoint for all three signals. `PrivacySettingsCache` gains `profilePhotoVisibility`, `blockedUserIds`, `clear()`, and `update(blockList:)`. `SessionService.clearSessionState()` calls `privacySettings.clear()`. `PrivacyView.swift` is split into focused files (`BlockedContactsView.swift`, `SanchrModeCard.swift`), its dead `@State` controls (Last Seen, About, Disappearing Messages) are deleted, hardcoded hex tile backgrounds are replaced with `SanchrExportColors.surfaceMuted`, and the four `.overlay { .stroke }` card borders are removed.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, XCTest, xcodebuild, `PrivacySettingsCache` (`NSLock`-guarded), `MessageRepositoryImpl` (gRPC via `GRPCClientProtocol`), `SanchrExportColors` design tokens.

**Spec:** `ios/Sanchr-iOS/docs/superpowers/specs/2026-04-10-privacy-audit-and-phase1-design.md`

**Project details:**
- Xcode project: `ios/Sanchr-iOS/Sanchr.xcodeproj`
- App target: `Sanchr`
- Test target: `SanchrTests` (sources in `ios/Sanchr-iOS/Tests/UnitTests/` only)
- Module import in tests: `@testable import Sanchr`
- Scheme: `Sanchr`

**Verification command** (used after every task that touches Swift code):

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -30
```

**Test command** (per-suite):

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/<TestClassName> \
  -quiet 2>&1 | tail -40
```

Replace `<TestClassName>` with the specific class for the task.

**Note on file paths in the plan:** all paths are relative to `/Users/soorajpandey/Projects/zynclave/sanchr`. Run xcodebuild from `ios/Sanchr-iOS` as shown in the commands.

**Note on test infrastructure limitation:** `MessageRepositoryImpl` has six hard-to-mock dependencies (`GRPCClientProtocol`, `LocalDatabaseProtocol`, `SignalProtocolManagerProtocol`, `ChatVaultPolicyMirror` (final class), `VaultRepositoryProtocol`, `MediaDownloadManager` (actor)). Unit-testing the class directly would require ~100+ stub methods. Phase 1 extracts the gate decision into a pure `MessagingPrivacyGate` struct that is trivially testable. The repository-level wiring (that every gated method actually consults the gate) is verified by grep invariants in Task 13, not by direct instantiation of `MessageRepositoryImpl`.

---

### Task 1: Extend `PrivacySettingsCache` with missing fields, `clear()`, and `update(blockList:)`

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Services/PrivacySettingsCache.swift`
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/PrivacySettingsCacheTests.swift`

The cache currently tracks only four flags. Phase 1 adds `_profilePhotoVisibility: String` (default `"everyone"`) and `_blockedUserIds: Set<String>` (default empty), a `clear()` reset, an `update(blockList:)` writer, and extends `update(from:)` to hydrate the new profile-photo field from the settings proto. Every mutation and read stays under the existing `NSLock`.

- [ ] **Step 1: Write the failing test for `clear()`**

Open `ios/Sanchr-iOS/Tests/UnitTests/PrivacySettingsCacheTests.swift` and append inside the test class (before the closing `}`):

```swift
func test_clear_resetsAllFields() {
    let cache = PrivacySettingsCache()

    var populated = Vync_Settings_UserSettings()
    populated.readReceipts = false
    populated.typingIndicator = false
    populated.onlineStatusVisible = false
    populated.vyncModeEnabled = true
    populated.profilePhotoVisibility = "contacts"
    cache.update(from: populated)
    cache.update(blockList: ["u1", "u2"])

    cache.clear()

    XCTAssertTrue(cache.canSendReadReceipts, "clear() restores readReceipts default")
    XCTAssertTrue(cache.canSendTypingIndicators)
    XCTAssertTrue(cache.canSendPresence)
    XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
    XCTAssertTrue(cache.blockedUserIds.isEmpty)
    XCTAssertFalse(cache.isBlocked("u1"))
}
```

- [ ] **Step 2: Run the test to verify it fails at compile time**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/PrivacySettingsCacheTests/test_clear_resetsAllFields \
  -quiet 2>&1 | tail -20
```

Expected: compile failure with `value of type 'PrivacySettingsCache' has no member 'clear'` and similar errors for `profilePhotoVisibility`, `blockedUserIds`, `isBlocked`, `update(blockList:)`.

- [ ] **Step 3: Extend `PrivacySettingsCache` with new fields, getters, and `clear()`**

Open `ios/Sanchr-iOS/Shared/Services/PrivacySettingsCache.swift` and replace the entire file contents with:

```swift
import Foundation
import OSLog
import SanchrShared

/// Thread-safe cached copy of user privacy settings.
/// Readable from any context. Updated after settings fetch/change.
/// Cleared on logout via `SessionService.clearSessionState()`.
final class PrivacySettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _readReceipts: Bool = true
    private var _typingIndicator: Bool = true
    private var _onlineStatusVisible: Bool = true
    private var _sanchrModeEnabled: Bool = false
    private var _profilePhotoVisibility: String = "everyone"
    private var _blockedUserIds: Set<String> = []

    var canSendReadReceipts: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _readReceipts && !_sanchrModeEnabled
    }

    var canSendTypingIndicators: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _typingIndicator && !_sanchrModeEnabled
    }

    var canSendPresence: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _onlineStatusVisible && !_sanchrModeEnabled
    }

    var profilePhotoVisibility: String {
        lock.lock()
        defer { lock.unlock() }
        return _profilePhotoVisibility
    }

    var blockedUserIds: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return _blockedUserIds
    }

    func isBlocked(_ userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _blockedUserIds.contains(userId)
    }

    /// Update cache from server settings response. Safe to call from any thread.
    func update(from settings: Vync_Settings_UserSettings) {
        lock.lock()
        _readReceipts = settings.readReceipts
        _typingIndicator = settings.typingIndicator
        _onlineStatusVisible = settings.onlineStatusVisible
        _sanchrModeEnabled = settings.vyncModeEnabled
        _profilePhotoVisibility = settings.profilePhotoVisibility.isEmpty
            ? "everyone"
            : settings.profilePhotoVisibility
        lock.unlock()
        SanchrLogger.settings.info(
            "Privacy cache updated: rr=\(settings.readReceipts), ti=\(settings.typingIndicator), os=\(settings.onlineStatusVisible), vm=\(settings.vyncModeEnabled), pp=\(settings.profilePhotoVisibility)"
        )
    }

    /// Updates the blocked-user set. Called after fetching the blocked list
    /// from ContactDataSource. Replaces the entire set atomically.
    func update(blockList: Set<String>) {
        lock.lock()
        _blockedUserIds = blockList
        lock.unlock()
        SanchrLogger.settings.info("Privacy cache blockList updated: count=\(blockList.count)")
    }

    /// Reset every field to its default. Called from
    /// `SessionService.clearSessionState()` so a logged-out session cannot
    /// leak the previous user's privacy state into a new login. Defaults are
    /// permissive (readReceipts/typing/presence on, sanchrMode off, profile
    /// photo visible to everyone, no blocks) to match Signal/WhatsApp
    /// cold-start conventions.
    func clear() {
        lock.lock()
        _readReceipts = true
        _typingIndicator = true
        _onlineStatusVisible = true
        _sanchrModeEnabled = false
        _profilePhotoVisibility = "everyone"
        _blockedUserIds = []
        lock.unlock()
        SanchrLogger.settings.info("Privacy cache cleared")
    }
}
```

- [ ] **Step 4: Run the first test to verify it passes**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/PrivacySettingsCacheTests/test_clear_resetsAllFields \
  -quiet 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Add the remaining cache tests**

Append inside `PrivacySettingsCacheTests`:

```swift
func test_updateFromSettings_populatesProfilePhotoVisibility() {
    let cache = PrivacySettingsCache()

    var settings = Vync_Settings_UserSettings()
    settings.profilePhotoVisibility = "contacts"
    cache.update(from: settings)

    XCTAssertEqual(cache.profilePhotoVisibility, "contacts")
}

func test_updateFromSettings_emptyProfilePhotoVisibilityFallsBackToEveryone() {
    let cache = PrivacySettingsCache()

    var settings = Vync_Settings_UserSettings()
    settings.profilePhotoVisibility = ""
    cache.update(from: settings)

    XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
}

func test_isBlocked_reflectsBlockListUpdate() {
    let cache = PrivacySettingsCache()

    cache.update(blockList: ["u1", "u2"])

    XCTAssertTrue(cache.isBlocked("u1"))
    XCTAssertTrue(cache.isBlocked("u2"))
    XCTAssertFalse(cache.isBlocked("u3"))
    XCTAssertEqual(cache.blockedUserIds, ["u1", "u2"])
}

func test_concurrentClearAndRead_doesNotCrash() {
    let cache = PrivacySettingsCache()

    let expectation = XCTestExpectation(description: "concurrent access")
    expectation.expectedFulfillmentCount = 2

    DispatchQueue.global().async {
        for _ in 0..<2000 {
            cache.clear()
        }
        expectation.fulfill()
    }

    DispatchQueue.global().async {
        for _ in 0..<2000 {
            _ = cache.canSendReadReceipts
            _ = cache.profilePhotoVisibility
            _ = cache.isBlocked("u1")
        }
        expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5.0)
}
```

- [ ] **Step 6: Run the full `PrivacySettingsCacheTests` suite**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/PrivacySettingsCacheTests \
  -quiet 2>&1 | tail -30
```

Expected: all existing tests PASS, all 5 new tests PASS.

- [ ] **Step 7: Commit**

```bash
git add ios/Sanchr-iOS/Shared/Services/PrivacySettingsCache.swift \
  ios/Sanchr-iOS/Tests/UnitTests/PrivacySettingsCacheTests.swift
git commit -m "$(cat <<'EOF'
feat(privacy): extend PrivacySettingsCache with profilePhotoVisibility, blockList, clear()

Adds the two missing privacy fields the cache could not previously
answer without a round-trip, plus clear() for logout-time reset and
update(blockList:) for after the blocked-list fetch. All operations
stay under the existing NSLock. Five new unit tests cover clear,
profile-photo round-trip with empty-string fallback, blockList updates,
and a concurrent clear/read stress test.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Create `MessagingPrivacyGate` struct and its 9 unit tests

**Files:**
- Create: `ios/Sanchr-iOS/Shared/Services/MessagingPrivacyGate.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/MessagingPrivacyGateTests.swift`

The gate struct is a pure value type that reads `PrivacySettingsCache` flags and returns `.allow` or `.suppress` for one of three signals. By extracting this logic from `MessageRepositoryImpl` we get a trivially testable unit, avoiding the need to stub ~100 protocol methods across six repository dependencies.

- [ ] **Step 1: Create `MessagingPrivacyGate.swift`**

Create `ios/Sanchr-iOS/Shared/Services/MessagingPrivacyGate.swift`:

```swift
import Foundation
import SanchrShared

/// Narrow gate wrapper that decides whether a privacy-sensitive messaging
/// signal should be dispatched. `MessageRepositoryImpl` holds an instance
/// constructed from the injected PrivacySettingsCache and consults it from
/// markAsRead, sendTypingIndicator, and sendPresenceHeartbeat.
///
/// Separated from the repository so the decision logic can be unit-tested
/// in isolation. Instantiating the full MessageRepositoryImpl would require
/// ~100 stub methods across six concrete dependencies (including two actors
/// and one final class).
struct MessagingPrivacyGate: Sendable {
    let privacySettings: PrivacySettingsCache

    enum Signal: Sendable, Equatable {
        case readReceipt
        case typingIndicator
        case presenceHeartbeat
    }

    enum Decision: Sendable, Equatable {
        case allow
        case suppress
    }

    func decide(_ signal: Signal) -> Decision {
        switch signal {
        case .readReceipt:
            return privacySettings.canSendReadReceipts ? .allow : .suppress
        case .typingIndicator:
            return privacySettings.canSendTypingIndicators ? .allow : .suppress
        case .presenceHeartbeat:
            return privacySettings.canSendPresence ? .allow : .suppress
        }
    }
}
```

- [ ] **Step 2: Create `MessagingPrivacyGateTests.swift` with the 9 scenarios**

Create `ios/Sanchr-iOS/Tests/UnitTests/MessagingPrivacyGateTests.swift`:

```swift
import XCTest
@testable import Sanchr
@testable import SanchrShared

final class MessagingPrivacyGateTests: XCTestCase {

    // MARK: - readReceipt

    func test_readReceipt_defaults_allow() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.readReceipt), .allow)
    }

    func test_readReceipt_disabled_suppress() {
        let gate = makeGate(
            readReceipts: false,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.readReceipt), .suppress)
    }

    func test_readReceipt_sanchrModeOn_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: true
        )

        XCTAssertEqual(
            gate.decide(.readReceipt),
            .suppress,
            "Sanchr Mode must override readReceipts=true"
        )
    }

    // MARK: - typingIndicator

    func test_typingIndicator_defaults_allow() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.typingIndicator), .allow)
    }

    func test_typingIndicator_disabled_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: false,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.typingIndicator), .suppress)
    }

    func test_typingIndicator_sanchrModeOn_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: true
        )

        XCTAssertEqual(gate.decide(.typingIndicator), .suppress)
    }

    // MARK: - presenceHeartbeat

    func test_presenceHeartbeat_defaults_allow() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.presenceHeartbeat), .allow)
    }

    func test_presenceHeartbeat_onlineStatusOff_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: false,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.presenceHeartbeat), .suppress)
    }

    func test_presenceHeartbeat_sanchrModeOn_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: true
        )

        XCTAssertEqual(gate.decide(.presenceHeartbeat), .suppress)
    }

    // MARK: - Helper

    private func makeGate(
        readReceipts: Bool,
        typingIndicator: Bool,
        onlineStatusVisible: Bool,
        sanchrMode: Bool
    ) -> MessagingPrivacyGate {
        let cache = PrivacySettingsCache()
        var settings = Vync_Settings_UserSettings()
        settings.readReceipts = readReceipts
        settings.typingIndicator = typingIndicator
        settings.onlineStatusVisible = onlineStatusVisible
        settings.vyncModeEnabled = sanchrMode
        settings.profilePhotoVisibility = "everyone"
        cache.update(from: settings)
        return MessagingPrivacyGate(privacySettings: cache)
    }
}
```

- [ ] **Step 3: Run the new test suite**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/MessagingPrivacyGateTests \
  -quiet 2>&1 | tail -30
```

Expected: all 9 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/Sanchr-iOS/Shared/Services/MessagingPrivacyGate.swift \
  ios/Sanchr-iOS/Tests/UnitTests/MessagingPrivacyGateTests.swift
git commit -m "$(cat <<'EOF'
feat(privacy): add MessagingPrivacyGate struct with 9 decision tests

MessagingPrivacyGate is a pure value type that decides .allow or
.suppress for .readReceipt / .typingIndicator / .presenceHeartbeat
signals based on PrivacySettingsCache state. Extracted from
MessageRepositoryImpl so the decision logic is unit-testable without
touching the repository's hard-to-mock dependency graph (six concrete
deps, two actors, one final class).

Nine tests cover the 3 signals × 3 flag-configuration coverage matrix
(defaults allow, individual flag disables, Sanchr Mode overrides).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire `MessagingPrivacyGate` into `MessageRepositoryImpl`

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift`

Add `privacySettings: PrivacySettingsCache` as a required init parameter. Construct a `privacyGate` stored property from it. Consult the gate in `markAsRead`, `sendTypingIndicator`, and `sendPresenceHeartbeat` before dispatching the network call. `markAsRead` falls through to `markAsReadLocally` on suppress so the local unread counter still clears.

- [ ] **Step 1: Add the stored properties to `MessageRepositoryImpl`**

Open `ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift` and find the `final class MessageRepositoryImpl: MessageRepositoryProtocol, @unchecked Sendable {` declaration at line 113. Locate the block of existing `private let` stored properties (around lines 114-123). After the last existing private let (`private let streamController = MessageStreamController()` around line 123), add:

```swift
    private let privacyGate: MessagingPrivacyGate
```

- [ ] **Step 2: Extend the init signature**

Replace the existing init (starts around line 125) with:

```swift
    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        signalProtocol: SignalProtocolManagerProtocol,
        chatVaultPolicyMirror: ChatVaultPolicyMirror,
        vaultRepository: VaultRepositoryProtocol,
        mediaDownloadManager: MediaDownloadManager,
        currentUserIdProvider: @escaping @Sendable () -> String? = { nil },
        privacySettings: PrivacySettingsCache
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.signalProtocol = signalProtocol
        self.chatVaultPolicyMirror = chatVaultPolicyMirror
        self.vaultRepository = vaultRepository
        self.mediaDownloadManager = mediaDownloadManager
        self.currentUserIdProvider = currentUserIdProvider
        self.privacyGate = MessagingPrivacyGate(privacySettings: privacySettings)
    }
```

- [ ] **Step 3: Gate `markAsRead`**

Locate `markAsRead` at line 296. Replace the existing body with:

```swift
    func markAsRead(conversationId: String, upToMessageId: String) async throws {
        switch privacyGate.decide(.readReceipt) {
        case .suppress:
            try await markAsReadLocally(
                conversationId: conversationId,
                upToMessageId: upToMessageId
            )
            SanchrLogger.chat.info(
                "markAsRead gated by privacy settings — local-only for \(conversationId.prefix(8))"
            )
            return
        case .allow:
            break
        }

        SanchrLogger.chat.info("Marking messages as read in \(conversationId) up to \(upToMessageId)")

        var request = Vync_Messaging_ReceiptRequest()
        request.conversationID = conversationId
        request.messageID = upToMessageId
        request.status = "read"

        _ = try await grpcClient.messagingService.sendReceipt(request)

        try await localDatabase.markConversationAsRead(
            conversationId: conversationId,
            upToMessageId: upToMessageId
        )
    }
```

- [ ] **Step 4: Gate `sendTypingIndicator`**

Locate `sendTypingIndicator` at line 492. Replace the body with:

```swift
    func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws {
        guard privacyGate.decide(.typingIndicator) == .allow else { return }

        SanchrLogger.chat.info("Sending typing indicator: \(isTyping) for \(conversationId)")

        var typingIndicator = Vync_Messaging_TypingIndicator()
        typingIndicator.conversationID = conversationId
        typingIndicator.userID = currentUserIdProvider() ?? ""
        typingIndicator.isTyping = isTyping

        var clientEvent = Vync_Messaging_ClientEvent()
        clientEvent.typing = typingIndicator
        await streamController.send(clientEvent)
    }
```

- [ ] **Step 5: Gate `sendPresenceHeartbeat`**

Locate `sendPresenceHeartbeat` at line 505. Replace the body with:

```swift
    func sendPresenceHeartbeat(
        deviceState: Vync_Messaging_DevicePresenceState,
        sentAtMs: Int64
    ) async throws {
        guard privacyGate.decide(.presenceHeartbeat) == .allow else { return }

        var heartbeat = Vync_Messaging_PresenceHeartbeat()
        heartbeat.deviceState = deviceState
        heartbeat.sentAtMs = sentAtMs

        var clientEvent = Vync_Messaging_ClientEvent()
        clientEvent.heartbeat = heartbeat
        await streamController.send(clientEvent)
    }
```

- [ ] **Step 6: Verify the build fails at `DependencyContainer` only**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: build fails at `DependencyContainer.swift` because the lazy `messageRepository` initializer no longer matches the new init signature (`privacySettings:` missing). Task 4 fixes that. Do NOT proceed to fix DependencyContainer here.

- [ ] **Step 7: Commit**

```bash
git add ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift
git commit -m "$(cat <<'EOF'
feat(privacy): gate MessageRepositoryImpl via MessagingPrivacyGate

Adds privacySettings: PrivacySettingsCache as a required init parameter,
constructs a private privacyGate stored property from it, and consults
the gate from markAsRead, sendTypingIndicator, and sendPresenceHeartbeat
before any network dispatch. Gated markAsRead falls through to
markAsReadLocally so local unread still clears. Typing and presence
return silently when suppressed.

DependencyContainer will fail to compile until Task 4 threads
privacySettings through the lazy messageRepository initializer.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Wire `privacySettings` into `MessageRepositoryImpl` via `DependencyContainer`

**Files:**
- Modify: `ios/Sanchr-iOS/App/DependencyContainer.swift:224-235`

The container's lazy `messageRepository` initializer needs the new argument. The cache already lives in the same container as `let privacySettings = PrivacySettingsCache()` (line 291), so the wiring is mechanical.

- [ ] **Step 1: Update the lazy initializer**

Open `ios/Sanchr-iOS/App/DependencyContainer.swift` and locate lines 224-235. Replace with:

```swift
    @ObservationIgnored lazy var messageRepository: MessageRepositoryProtocol = {
        nonisolated(unsafe) weak var weakSelf = self
        return MessageRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: localDatabase,
            signalProtocol: signalSessionManager,
            chatVaultPolicyMirror: chatVaultPolicyMirror,
            vaultRepository: vaultRepository,
            mediaDownloadManager: mediaDownloadManager,
            currentUserIdProvider: { weakSelf?.sessionService.currentUserId },
            privacySettings: privacySettings
        )
    }()
```

- [ ] **Step 2: Verify the app target builds**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. The test target may still fail until Task 6 — that's OK.

- [ ] **Step 3: Commit**

```bash
git add ios/Sanchr-iOS/App/DependencyContainer.swift
git commit -m "$(cat <<'EOF'
wire(privacy): thread PrivacySettingsCache into MessageRepositoryImpl

DependencyContainer now passes privacySettings when constructing
messageRepository, closing the compile break introduced by Task 3.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Add `privacySettings` dependency to `SessionService` and clear cache on logout

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Services/SessionService.swift`
- Modify: `ios/Sanchr-iOS/App/DependencyContainer.swift:271-282`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/SessionServicePrivacyClearTests.swift`

`SessionService.init` gains a `privacySettings: PrivacySettingsCache` parameter. `clearSessionState()` calls `privacySettings.clear()` as its first action. Two unit tests cover the reset and idempotency.

- [ ] **Step 1: Write the failing tests**

Create `ios/Sanchr-iOS/Tests/UnitTests/SessionServicePrivacyClearTests.swift`:

```swift
import XCTest
@testable import Sanchr
@testable import SanchrShared

final class SessionServicePrivacyClearTests: XCTestCase {

    func test_clearSession_resetsCacheToDefaults() async throws {
        let cache = PrivacySettingsCache()
        var populated = Vync_Settings_UserSettings()
        populated.readReceipts = false
        populated.typingIndicator = false
        populated.onlineStatusVisible = false
        populated.vyncModeEnabled = true
        populated.profilePhotoVisibility = "nobody"
        cache.update(from: populated)
        cache.update(blockList: ["u1"])

        XCTAssertFalse(cache.canSendReadReceipts)
        XCTAssertFalse(cache.canSendTypingIndicators)
        XCTAssertEqual(cache.profilePhotoVisibility, "nobody")
        XCTAssertTrue(cache.isBlocked("u1"))

        let service = SessionService(
            secureStorage: MockSecureStorage(),
            authRepository: MockAuthRepository(),
            privacySettings: cache
        )
        try await service.clearSession()

        XCTAssertTrue(cache.canSendReadReceipts, "clear on logout must restore defaults")
        XCTAssertTrue(cache.canSendTypingIndicators)
        XCTAssertTrue(cache.canSendPresence)
        XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
        XCTAssertTrue(cache.blockedUserIds.isEmpty)
    }

    func test_clearSession_idempotent() async throws {
        let cache = PrivacySettingsCache()
        let service = SessionService(
            secureStorage: MockSecureStorage(),
            authRepository: MockAuthRepository(),
            privacySettings: cache
        )

        try await service.clearSession()
        try await service.clearSession()

        XCTAssertTrue(cache.canSendReadReceipts)
        XCTAssertEqual(cache.profilePhotoVisibility, "everyone")
    }
}
```

- [ ] **Step 2: Run the test to verify compile failure**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/SessionServicePrivacyClearTests \
  -quiet 2>&1 | tail -20
```

Expected: compile fails because `SessionService.init` does not accept `privacySettings:`.

- [ ] **Step 3: Add `privacySettings` to `SessionService`**

Open `ios/Sanchr-iOS/Shared/Services/SessionService.swift`. After line 11 (`private let deepWipe: @Sendable () async -> Void`) add:

```swift
    private let privacySettings: PrivacySettingsCache
```

Replace the existing init (lines 43-54) with:

```swift
    init(
        secureStorage: SecureStorageProtocol,
        authRepository: AuthRepositoryProtocol,
        privacySettings: PrivacySettingsCache,
        cleanup: @escaping @Sendable () async -> Void = {},
        deepWipe: @escaping @Sendable () async -> Void = {}
    ) {
        self.secureStorage = secureStorage
        self.authRepository = authRepository
        self.privacySettings = privacySettings
        self.cleanup = cleanup
        self.deepWipe = deepWipe
        restorePersistedSession()
    }
```

- [ ] **Step 4: Call `clear()` inside `clearSessionState`**

Replace `clearSessionState` (lines 242-252) with:

```swift
    @MainActor
    private func clearSessionState() {
        privacySettings.clear()
        isAuthenticated = false
        currentUserId = nil
        currentDisplayName = nil
        currentPhoneNumber = nil
        currentAvatarURL = nil
        currentDeviceId = nil
        currentInstallationId = nil
        lastMessageSyncTimestamp = 0
        tokenExpiresAt = nil
    }
```

- [ ] **Step 5: Update `DependencyContainer` to pass `privacySettings` into `SessionService`**

Open `ios/Sanchr-iOS/App/DependencyContainer.swift` and replace lines 271-282 with:

```swift
    @ObservationIgnored lazy var sessionService: SessionService = SessionService(
        secureStorage: secureStorage,
        authRepository: authRepository,
        privacySettings: privacySettings,
        cleanup: {
            nonisolated(unsafe) weak var weakSelf = self
            await weakSelf?.wipeLocalSessionArtifacts()
        },
        deepWipe: {
            nonisolated(unsafe) weak var weakSelf = self
            await weakSelf?.wipeAppGroupArtifacts()
        }
    )
```

- [ ] **Step 6: Verify the new tests compile but existing tests may break**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/SessionServicePrivacyClearTests \
  -quiet 2>&1 | tail -30
```

Expected: either the `SessionServicePrivacyClearTests` PASS, or the test target fails to compile because `SessionServiceTests.swift` / `RealtimeServiceTests.swift` still use the old init. Task 6 will fix the latter.

- [ ] **Step 7: Commit**

```bash
git add ios/Sanchr-iOS/Shared/Services/SessionService.swift \
  ios/Sanchr-iOS/App/DependencyContainer.swift \
  ios/Sanchr-iOS/Tests/UnitTests/SessionServicePrivacyClearTests.swift
git commit -m "$(cat <<'EOF'
feat(privacy): clear PrivacySettingsCache on SessionService logout

SessionService now takes privacySettings as a required init parameter
and calls privacySettings.clear() as the first line of clearSessionState().
Defaults are permissive (readReceipts/typing/presence on, sanchrMode off,
profile photo visible to everyone) so a cold-start session after logout
does not silently suppress signals the user had enabled.

Two new tests cover the reset + idempotency. Existing SessionService and
RealtimeService test fixtures still break on the new init signature;
Task 6 updates them.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Fix existing test compile breaks from the new `SessionService` init signature

**Files:**
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/SessionServiceTests.swift`
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/RealtimeServiceTests.swift`

Existing tests construct `SessionService(...)` directly and now fail to compile on the new required argument. Add `privacySettings:` at every call site.

- [ ] **Step 1: Locate the `SessionService` construction sites**

```bash
grep -n "SessionService(" ios/Sanchr-iOS/Tests/UnitTests/SessionServiceTests.swift \
  ios/Sanchr-iOS/Tests/UnitTests/RealtimeServiceTests.swift 2>&1 | head -10
```

Expected: three hits in `SessionServiceTests.swift` and one hit in `RealtimeServiceTests.swift`.

- [ ] **Step 2: Update each `SessionServiceTests.swift` call site**

Open `ios/Sanchr-iOS/Tests/UnitTests/SessionServiceTests.swift`. At each of the three `SessionService(...)` call sites, add `privacySettings: PrivacySettingsCache()` as a positional argument after `authRepository:` and before any `cleanup:` / `deepWipe:` arguments:

```swift
let service = SessionService(
    secureStorage: secureStorage,
    authRepository: authRepository,
    privacySettings: PrivacySettingsCache()
)
```

Keep any existing `cleanup:` / `deepWipe:` closures after the new argument. Repeat for all three sites.

- [ ] **Step 3: Update `RealtimeServiceTests.swift` helper**

Open `ios/Sanchr-iOS/Tests/UnitTests/RealtimeServiceTests.swift` and locate the `makeAuthenticatedSessionService` helper. Add the new argument:

```swift
    private func makeAuthenticatedSessionService() async throws -> SessionService {
        let service = SessionService(
            secureStorage: MockSecureStorage(),
            authRepository: MockAuthRepository(),
            privacySettings: PrivacySettingsCache()
        )
        // preserve any existing post-init setup calls
        return service
    }
```

If the helper had additional setup code after the init, keep it unchanged.

- [ ] **Step 4: Build the test target**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build-for-testing 2>&1 | tail -30
```

Expected: `BUILD SUCCEEDED`. If compile errors remain, grep for any missed `SessionService(` or `MessageRepositoryImpl(` sites:

```bash
grep -rn "SessionService(\|MessageRepositoryImpl(" ios/Sanchr-iOS/Tests 2>&1 | head -10
```

Fix any hit that doesn't pass `privacySettings:`.

- [ ] **Step 5: Run the core test suites together**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/MessagingPrivacyGateTests \
  -only-testing:SanchrTests/PrivacySettingsCacheTests \
  -only-testing:SanchrTests/SessionServicePrivacyClearTests \
  -only-testing:SanchrTests/SessionServiceTests \
  -only-testing:SanchrTests/RealtimeServiceTests \
  -quiet 2>&1 | tail -40
```

Expected: every listed suite PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/Sanchr-iOS/Tests/UnitTests/SessionServiceTests.swift \
  ios/Sanchr-iOS/Tests/UnitTests/RealtimeServiceTests.swift
git commit -m "$(cat <<'EOF'
test(privacy): fix SessionService test compile breaks after new init arg

Adds privacySettings: PrivacySettingsCache() to SessionService
constructors across SessionServiceTests (3 sites) and
RealtimeServiceTests (1 helper). Closes the test-target compile break
introduced by Task 5.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Drop call-site gate checks in `RealtimeService`, `ChatDetailView`, and `ChatDetailViewModel`

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Services/RealtimeService.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailViewModel.swift`

With the gates now inside `MessageRepositoryImpl` (via `MessagingPrivacyGate`), every caller drops its manual check. The `canSend:` parameter on the view model's typing methods goes away, and the `if/else` fork around `markAsRead` collapses to a single repo call. `RealtimeService` stops guarding `sendPresenceHeartbeat`.

- [ ] **Step 1: Remove the three `canSendPresence` guards in `RealtimeService`**

Open `ios/Sanchr-iOS/Shared/Services/RealtimeService.swift`.

Find line 186-191:

```swift
        Task {
            if privacySettings.canSendPresence {
                try? await sendPresenceHeartbeat(.foreground)
            }
            await refreshPresenceSnapshot(for: Array(trackedPeerIds))
        }
```

Replace with:

```swift
        Task {
            try? await sendPresenceHeartbeat(.foreground)
            await refreshPresenceSnapshot(for: Array(trackedPeerIds))
        }
```

Find line 202-208:

```swift
        Task {
            if privacySettings.canSendPresence {
                try? await sendPresenceHeartbeat(.background)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            stop()
        }
```

Replace with:

```swift
        Task {
            try? await sendPresenceHeartbeat(.background)
            try? await Task.sleep(nanoseconds: 200_000_000)
            stop()
        }
```

Find the reconnect-loop heartbeat guard (around line 363-366):

```swift
                guard privacySettings.canSendPresence else { continue }
                try? await sendPresenceHeartbeat(.foreground)
```

Replace with:

```swift
                try? await sendPresenceHeartbeat(.foreground)
```

Leave the `privacySettings` init parameter and stored property in place — future filters on inbound events will reuse it.

- [ ] **Step 2: Drop `canSend` parameter from `ChatDetailViewModel` typing methods**

Open `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailViewModel.swift`. Locate the `sendTypingIndicator` method at around line 841. Remove the `canSend: Bool` parameter and its guard from `sendTypingIndicator`, `stopTypingIndicator`, and any private `setTypingIndicator` helper. The resulting shape should be:

```swift
    func sendTypingIndicator(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        do {
            try await messageRepository.sendTypingIndicator(
                conversationId: conversationId,
                isTyping: true
            )
        } catch {
            SanchrLogger.chat.error("Failed to send typing indicator: \(error.localizedDescription)")
        }
    }

    func stopTypingIndicator(
        conversationId: String,
        messageRepository: MessageRepositoryProtocol
    ) async {
        do {
            try await messageRepository.sendTypingIndicator(
                conversationId: conversationId,
                isTyping: false
            )
        } catch {
            SanchrLogger.chat.error("Failed to stop typing indicator: \(error.localizedDescription)")
        }
    }
```

If there is a `setTypingIndicator(...)` private helper that delegates to these two, update it the same way — drop its `canSend` parameter and let it route through the gated repo calls. If the existing implementation uses a debounce timer or throttling wrapper, preserve the wrapper logic; only the gate plumbing is removed.

- [ ] **Step 3: Update `ChatDetailView.swift` call sites**

Open `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`.

Find the `.onDisappear` block around line 381-386:

```swift
            Task {
                await viewModel.stopTypingIndicator(
                    conversationId: conversation.id,
                    messageRepository: container.messageRepository,
                    canSend: container.privacySettings.canSendTypingIndicators
                )
            }
```

Replace with:

```swift
            Task {
                await viewModel.stopTypingIndicator(
                    conversationId: conversation.id,
                    messageRepository: container.messageRepository
                )
            }
```

Find the auto-mark-read on incoming message, around line 419-428:

```swift
            // Auto-mark incoming messages as read — gate receipt sending on privacy setting
            if container.privacySettings.canSendReadReceipts {
                try? await container.messageRepository.markAsRead(
                    conversationId: conversation.id,
                    upToMessageId: message.id
                )
            } else {
                try? await container.messageRepository.markAsReadLocally(
                    conversationId: conversation.id,
                    upToMessageId: message.id
                )
            }
```

Replace with:

```swift
            // Auto-mark incoming messages as read — repo gates receipts internally.
            try? await container.messageRepository.markAsRead(
                conversationId: conversation.id,
                upToMessageId: message.id
            )
```

Find the two additional typing dispatch sites around lines 473-487 that pass `canSend: container.privacySettings.canSendTypingIndicators` and drop the `canSend:` argument from both.

Find the second auto-mark-read site around line 1219-1228 (same structure as the first one) and collapse the branch the same way — single `markAsRead` call, no if/else.

- [ ] **Step 4: Verify the app target builds**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Grep for leftover `canSend:` arguments**

```bash
grep -rn "canSend:" ios/Sanchr-iOS/Features ios/Sanchr-iOS/Shared 2>&1 | grep -v "canSendReadReceipts\|canSendTypingIndicators\|canSendPresence\|privacySettings\.canSend"
```

Expected: zero results. The cache getters (`canSendReadReceipts`, `canSendTypingIndicators`, `canSendPresence`) are still referenced inside the gate struct, but no view/viewmodel passes `canSend:` as an argument.

- [ ] **Step 6: Run the core suites once more**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:SanchrTests/MessagingPrivacyGateTests \
  -only-testing:SanchrTests/PrivacySettingsCacheTests \
  -only-testing:SanchrTests/SessionServicePrivacyClearTests \
  -quiet 2>&1 | tail -30
```

Expected: every test PASS.

- [ ] **Step 7: Commit**

```bash
git add ios/Sanchr-iOS/Shared/Services/RealtimeService.swift \
  ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift \
  ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailViewModel.swift
git commit -m "$(cat <<'EOF'
refactor(privacy): drop call-site gate checks now the repo gates inside

RealtimeService stops guarding sendPresenceHeartbeat — the repository
now handles it. ChatDetailView drops the if/else fork around markAsRead
(repo falls through to markAsReadLocally when gated) and the canSend:
argument on typing dispatch. ChatDetailViewModel's typing methods lose
the canSend: Bool parameter entirely.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Extract `BlockedContactsView` into its own file

**Files:**
- Create: `ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift`
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`

Step 0 of the PrivacyView cleanup: move the nested `BlockedContactsView` (lines 418-525 of `PrivacyView.swift`) into its own file before touching the rest of the privacy screen. The extraction is a pure move — no content changes.

- [ ] **Step 1: Create the new file with the extracted view**

Create `ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift`:

```swift
import SwiftUI
import SanchrShared

/// Sub-screen showing the list of blocked contacts with unblock actions.
/// Fetches the list from ContactDataSource.getBlockedList() and lets
/// the user unblock individual contacts inline.
struct BlockedContactsView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var blockedIDs: [String] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                if isLoading {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if blockedIDs.isEmpty {
                    VStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: 0xF3F4F6))
                            .frame(width: 72, height: 72)
                            .overlay {
                                Image(systemName: "hand.raised.slash.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                            }
                        Text("No blocked contacts")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text("You can block someone from any conversation if needed.")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    VStack(spacing: 12) {
                        ForEach(blockedIDs, id: \.self) { userId in
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(Color(hex: 0xFEE2E2))
                                    .frame(width: 42, height: 42)
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .foregroundColor(.sanchrError)
                                    }

                                Text(shortID(userId))
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)

                                Spacer()

                                Button("Unblock") {
                                    Task { await unblock(userId: userId) }
                                }
                                .font(SanchrTypography.caption)
                                .foregroundColor(.sanchrError)
                            }
                            .padding(16)
                            .background(SanchrExportColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                            }
                        }
                    }
                    .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Blocked Contacts")
        .task {
            await loadBlocked()
        }
    }

    private func shortID(_ userId: String) -> String {
        let prefix = String(userId.prefix(12))
        return userId.count > 12 ? "\(prefix)..." : prefix
    }

    private func loadBlocked() async {
        isLoading = true
        defer { isLoading = false }

        let dataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        do {
            blockedIDs = try await dataSource.getBlockedList()
        } catch {
            SanchrLogger.sync.error("Failed to load blocked list: \(error.localizedDescription)")
        }
    }

    private func unblock(userId: String) async {
        let dataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        do {
            try await dataSource.unblockContact(userId: userId)
            blockedIDs.removeAll { $0 == userId }
        } catch {
            SanchrLogger.sync.error("Failed to unblock: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Delete the old `BlockedContactsView` from `PrivacyView.swift`**

Open `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`. Locate the `/// Sub-screen showing the list of blocked contacts with unblock actions.` comment (around line 417) and the `struct BlockedContactsView: View { ... }` block that follows (lines 418-525). Delete the comment and the entire struct. Save the file.

- [ ] **Step 3: Verify the build**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. The `NavigationLink { BlockedContactsView() }` in `PrivacyView` resolves to the new file because the type name matches.

- [ ] **Step 4: Commit**

```bash
git add ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift
git commit -m "$(cat <<'EOF'
refactor(privacy): extract BlockedContactsView into its own file

Pure move from PrivacyView.swift:418-525. No behavior change. Dark
theme token replacement and border removal on the row cards land in
later tasks in this sprint.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Extract `SanchrModeCard` into its own file

**Files:**
- Create: `ios/Sanchr-iOS/Features/Settings/Presentation/SanchrModeCard.swift`
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`

Extract the hero gradient card at the top of Privacy into its own reusable subview.

- [ ] **Step 1: Create the new file**

Create `ios/Sanchr-iOS/Features/Settings/Presentation/SanchrModeCard.swift`:

```swift
import SwiftUI
import SanchrShared

/// Hero card at the top of the Privacy screen that toggles Sanchr Mode.
/// The two pills below the toggle describe the behaviors Sanchr Mode
/// enables (silent notifications, hidden previews). Gradient is
/// intentionally dark in both light and dark themes.
struct SanchrModeCard: View {
    @Binding var isOn: Bool
    var onToggleChanged: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(SanchrColors.accent)

                        Text("Sanchr Mode")
                            .font(SanchrTypography.cardTitle)
                            .foregroundColor(.white)
                    }

                    Text("Enhanced privacy with hidden previews and a more discreet interface.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer()

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(SanchrColors.accent)
                    .onChange(of: isOn) { _, _ in
                        Task { await onToggleChanged() }
                    }
            }

            HStack(spacing: 12) {
                statPill(icon: "bell.slash.fill", title: "Silent Notifications")
                statPill(icon: "eye.slash.fill", title: "Hidden Previews")
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x111827), Color(hex: 0x0F172A)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func statPill(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))
            Text(title)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
```

- [ ] **Step 2: Replace the inline `sanchrModeCard` computed property in `PrivacyView`**

Open `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`. Find the `private var sanchrModeCard: some View` computed property (around lines 49-94). Replace the entire property body plus the inner `statPill` helper (if still present as a method on PrivacyView) with:

```swift
    private var sanchrModeCard: some View {
        SanchrModeCard(
            isOn: $viewModel.vyncModeEnabled,
            onToggleChanged: {
                await viewModel.toggleVyncMode(settingsDataSource: settingsDataSource)
            }
        )
    }
```

Also delete the `private func statPill(icon:title:) -> some View` helper from `PrivacyView` — it has moved into `SanchrModeCard`.

- [ ] **Step 3: Verify the build**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add ios/Sanchr-iOS/Features/Settings/Presentation/SanchrModeCard.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift
git commit -m "$(cat <<'EOF'
refactor(privacy): extract SanchrModeCard into its own file

Pure move of the hero gradient card plus its statPill helper into a
dedicated SanchrModeCard view. Takes an isOn binding and an async
onToggleChanged callback so the parent owns the viewModel + data-source
plumbing. Gradient stays dark in both themes by design.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Remove dead state — Last Seen, About, Disappearing Messages

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`

Delete three `@State` vars, their corresponding Menu blocks, the `disappearingOptions` array, and the `.task { lastSeenVisibility = ... }` hydration line. After this task, `accountPrivacySection` shows only Profile Photo and Read Receipts; `securityFeaturesSection` shows only App Lock and Secret Vault.

- [ ] **Step 1: Delete the three `@State` vars and `disappearingOptions` array**

Open `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`. Delete these three lines from the top of `PrivacyView`:

```swift
    @State private var lastSeenVisibility = "nobody"
    @State private var aboutVisibility = "everyone"
    @State private var disappearingDefault = "24h"
```

Delete the `disappearingOptions` array that follows:

```swift
    private let disappearingOptions = [
        ("Off", "off"),
        ("24 hours", "24h"),
        ("7 days", "7d"),
        ("90 days", "90d"),
    ]
```

Keep the `visibilityOptions` array (still used by the Profile Photo menu via `visibilityMenuSelection`). The only `@State` var that should remain in `PrivacyView` after this step is `@State private var viewModel = SettingsViewModel()`.

- [ ] **Step 2: Delete the Last Seen menu from `accountPrivacySection`**

Delete the first `Menu { visibilityMenuSelection(for: $lastSeenVisibility, syncsToBackend: false) } label: { cardRow(...title: "Last Seen", ...) } .buttonStyle(.plain)` block in `accountPrivacySection`.

- [ ] **Step 3: Delete the About menu from `accountPrivacySection`**

Delete the `Menu { visibilityMenuSelection(for: $aboutVisibility, syncsToBackend: false) } label: { cardRow(...title: "About", ...) } .buttonStyle(.plain)` block in `accountPrivacySection`. After this deletion, `accountPrivacySection` contains exactly the Profile Photo menu and the Read Receipts row.

- [ ] **Step 4: Delete the Disappearing Messages menu from `securityFeaturesSection`**

Delete the entire `Menu { ForEach(disappearingOptions, id: \.1) { ... } } label: { cardRow(...title: "Disappearing Messages", ...) } .buttonStyle(.plain)` block inside `securityFeaturesSection`. After deletion, `securityFeaturesSection` contains exactly App Lock and Secret Vault navigation links.

- [ ] **Step 5: Delete the `.task { lastSeenVisibility = ... }` hydration line**

Inside the `.task { await viewModel.loadSettings(...) }` block, delete the line:

```swift
            lastSeenVisibility = viewModel.onlineStatusVisible ? "contacts" : "nobody"
```

The `.task` block now only contains the `await viewModel.loadSettings(...)` call.

- [ ] **Step 6: Verify the build**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. Any compile error mentioning `lastSeenVisibility`, `aboutVisibility`, `disappearingDefault`, or `disappearingOptions` indicates a missed deletion:

```bash
grep -n "lastSeenVisibility\|aboutVisibility\|disappearingDefault\|disappearingOptions" ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift
```

Expected: zero results.

- [ ] **Step 7: Commit**

```bash
git add ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift
git commit -m "$(cat <<'EOF'
chore(privacy): remove dead UI state — Last Seen, About, Disappearing Messages

These three controls persisted nothing — pure @State vars backed by no
proto field, no debouncedSync() call, and no local storage. Users
toggled them expecting something to happen; nothing did. Remove the
rows entirely instead of pretending they work.

- Last Seen is redundant with the Online Status toggle that actually works.
- About visibility is not implemented anywhere.
- Disappearing Messages default requires backend + per-conversation TTL;
  when built as a real feature it belongs under Chats, not Privacy.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Remove the four `.overlay { .stroke }` card borders

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift`

Delete every `.overlay { RoundedRectangle(cornerRadius: X, style: .continuous).stroke(Color(hex: 0xE5E7EB), lineWidth: 1) }` block across both files. User explicitly asked for these to go.

- [ ] **Step 1: Delete the read-receipts row border in `PrivacyView.swift`**

Open `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`. Locate the Read Receipts row HStack inside `accountPrivacySection`. It has a `.background(SanchrExportColors.surface).clipShape(...).overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(hex: 0xE5E7EB), lineWidth: 1) }`. Delete the entire `.overlay { ... }` call, keeping the `.background` and `.clipShape` calls intact.

- [ ] **Step 2: Delete the controls-section border**

Inside `controlsSection`, find the card wrapping the two stacked toggle rows. It has `.background(SanchrExportColors.surface).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color(hex: 0xE5E7EB), lineWidth: 1) }`. Delete the `.overlay { ... }` call.

- [ ] **Step 3: Delete the generic `cardRow` border**

Locate the `cardRow` helper method inside `PrivacyView`. Its last modifier chain includes `.background(SanchrExportColors.surface).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(hex: 0xE5E7EB), lineWidth: 1) }`. Delete the `.overlay { ... }` call. This single deletion clears the border from Profile Photo, App Lock, Secret Vault, and Blocked Contacts rows because they all go through `cardRow`.

- [ ] **Step 4: Delete the blocked-row border in `BlockedContactsView.swift`**

Open `ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift`. Inside the `ForEach(blockedIDs)` block, find the row that has `.background(SanchrExportColors.surface).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(hex: 0xE5E7EB), lineWidth: 1) }`. Delete the `.overlay { ... }` call.

- [ ] **Step 5: Verify no stroke overlays remain in these two files**

```bash
grep -n "Color(hex: 0xE5E7EB)" \
  ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift
```

Expected: zero results.

- [ ] **Step 6: Verify the build**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift
git commit -m "$(cat <<'EOF'
style(privacy): remove extra card borders across Privacy screen

User explicitly asked for the 0xE5E7EB stroke overlays to go. Four
deletions total: read receipts row, controls section card, the shared
cardRow helper (affects Profile Photo, App Lock, Secret Vault, Blocked
Contacts), and blocked-row cards in BlockedContactsView. Resulting
cards are pure filled surfaces via clipShape + background.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Replace hardcoded hex tints with `SanchrExportColors.surfaceMuted` (dark theme fix)

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift`

Replace every hardcoded pastel `Color(hex: 0x...)` in these two files with `SanchrExportColors.surfaceMuted`. Collapse the `iconTile` helper to a single-argument form and drop `tint:` / `background:` from `cardRow` and `stackedToggleRow`.

- [ ] **Step 1: Simplify the `iconTile` helper in `PrivacyView`**

Open `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift`. Locate the `iconTile(systemName:tint:background:)` helper method (around line 374). Replace the entire method with:

```swift
    private func iconTile(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SanchrExportColors.surfaceMuted)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.sanchrPrimary)
            }
    }
```

- [ ] **Step 2: Simplify `cardRow` and `stackedToggleRow` signatures**

Locate the `cardRow(icon:tint:background:title:subtitle:trailing:)` method in `PrivacyView.swift`. Replace with:

```swift
    private func cardRow(
        icon: String,
        title: String,
        subtitle: String,
        trailing: AnyView
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            trailing
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
```

Locate the `stackedToggleRow(icon:tint:background:title:subtitle:isOn:onChange:)` method. Replace with:

```swift
    private func stackedToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
                .onChange(of: isOn.wrappedValue) { _, _ in
                    onChange()
                }
        }
        .padding(.vertical, 12)
    }
```

- [ ] **Step 3: Update every `cardRow(...)` and `stackedToggleRow(...)` call site in `PrivacyView`**

Throughout `PrivacyView.swift`, find every remaining call to `cardRow(icon:tint:background:title:subtitle:trailing:)` and delete the `tint:` and `background:` arguments. Example transformation:

Before:
```swift
cardRow(
    icon: "lock.fill",
    tint: SanchrColors.primary,
    background: Color(hex: 0xEEF2FF),
    title: "App Lock",
    subtitle: "Biometric and timeout controls",
    trailing: AnyView(chevron)
)
```

After:
```swift
cardRow(
    icon: "lock.fill",
    title: "App Lock",
    subtitle: "Biometric and timeout controls",
    trailing: AnyView(chevron)
)
```

Do the same for `stackedToggleRow(...)` calls in `controlsSection` — drop `tint:` and `background:`.

Also update the Read Receipts row inside `accountPrivacySection`. It is built inline (not through `cardRow`) and currently uses `iconTile(systemName: "checkmark.message.fill", tint: Color(hex: 0x16A34A), background: Color(hex: 0xDCFCE7))`. Change that call to `iconTile(systemName: "checkmark.message.fill")`.

- [ ] **Step 4: Update `BlockedContactsView` circle fills**

Open `ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift`. Find the empty-state circle:

```swift
                        Circle()
                            .fill(Color(hex: 0xF3F4F6))
```

Replace `Color(hex: 0xF3F4F6)` with `SanchrExportColors.surfaceMuted`.

Find the unblock-row circle:

```swift
                                Circle()
                                    .fill(Color(hex: 0xFEE2E2))
```

Replace `Color(hex: 0xFEE2E2)` with `SanchrExportColors.surfaceMuted`.

- [ ] **Step 5: Verify no hardcoded pastel hex remains**

```bash
grep -nE "Color\(hex: 0x(EEF2FF|ECFEFF|F3E8FF|DCFCE7|FFEDD5|FEE2E2|F3F4F6|16A34A|7C3AED|EA580C|DC2626)\)" \
  ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift
```

Expected: zero results. The Sanchr Mode hero gradient (`0x111827` / `0x0F172A`) lives in `SanchrModeCard.swift` and is intentionally dark in both themes.

- [ ] **Step 6: Verify the build**

```bash
cd ios/Sanchr-iOS && xcodebuild \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet \
  build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Manual dark-mode verification**

Boot the simulator (`iPhone 16 Pro`), sign into the app, navigate to Settings → Privacy. Toggle the simulator into dark mode (`Features → Toggle Appearance` or `⌘⇧A`). Confirm:

- Background is dark.
- Card surfaces are dark-adapted (no bright patches).
- Icon tiles are uniform `surfaceMuted` with the primary-colored SF Symbol visible.
- Sanchr Mode hero card stays dark gradient (intentional).
- No stroke borders around any card.
- Only these rows appear: Sanchr Mode hero, Profile Photo, Read Receipts, App Lock, Secret Vault, Online Status, Typing Indicators, Blocked contacts.

Toggle back to light mode and confirm the same layout is still readable and visually balanced.

- [ ] **Step 8: Commit**

```bash
git add ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift
git commit -m "$(cat <<'EOF'
style(privacy): adopt SanchrExportColors tokens for dark-theme support

Replaces every hardcoded pastel hex (0xEEF2FF, 0xECFEFF, 0xF3E8FF,
0xDCFCE7, 0xFFEDD5, 0xFEE2E2, 0xF3F4F6) with SanchrExportColors.surfaceMuted
which adapts to dark mode via the token system. Collapses iconTile to
a single-argument form (systemName:) and drops tint:/background: from
cardRow and stackedToggleRow. Tile symbols unify on .sanchrPrimary
and destructive rows keep .sanchrError.

BlockedContactsView's empty-state and unblock row circles follow the
same substitution. Sanchr Mode's hero gradient stays dark-in-both-themes
by design.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Full workspace verification + tag

**Files:** none (verification only)

Final checks: entire test suite green, gate-wiring invariants hold, no stragglers, clean xcodebuild.

- [ ] **Step 1: Run the full test suite**

```bash
cd ios/Sanchr-iOS && xcodebuild test \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet 2>&1 | tail -60
```

Expected: all tests PASS. If a pre-existing unrelated failure exists, note it but do not fix in this sprint.

- [ ] **Step 2: Gate-wiring grep invariants**

Prove that every privacy-sensitive method in `MessageRepositoryImpl` consults the gate before dispatching any network call. Three separate greps:

```bash
# Invariant 1: markAsRead must contain a privacyGate.decide(.readReceipt) call
awk '/^    func markAsRead/,/^    }/' ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift | grep -c "privacyGate.decide(.readReceipt)"
```

Expected: `1` (exactly one gate call per method).

```bash
# Invariant 2: sendTypingIndicator must contain a privacyGate.decide(.typingIndicator) call
awk '/^    func sendTypingIndicator/,/^    }/' ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift | grep -c "privacyGate.decide(.typingIndicator)"
```

Expected: `1`.

```bash
# Invariant 3: sendPresenceHeartbeat must contain a privacyGate.decide(.presenceHeartbeat) call
awk '/^    func sendPresenceHeartbeat/,/^    }/' ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift | grep -c "privacyGate.decide(.presenceHeartbeat)"
```

Expected: `1`.

If any of these grep counts is zero, Task 3 missed a method. Go back and fix before proceeding.

- [ ] **Step 3: Grep for leftover `canSend:` arguments**

```bash
grep -rn "canSend:" ios/Sanchr-iOS/Features ios/Sanchr-iOS/Shared 2>&1 | grep -v "canSendReadReceipts\|canSendTypingIndicators\|canSendPresence\|privacySettings\.canSend"
```

Expected: zero results.

- [ ] **Step 4: Grep for leftover dead state**

```bash
grep -rn "lastSeenVisibility\|aboutVisibility\|disappearingDefault\|disappearingOptions" ios/Sanchr-iOS/Features ios/Sanchr-iOS/Shared ios/Sanchr-iOS/App
```

Expected: zero results in app source (historical references in `ios/Sanchr-iOS/docs/` are acceptable).

- [ ] **Step 5: Grep for leftover hex pastels in Privacy screens**

```bash
grep -rnE "Color\(hex: 0x(EEF2FF|ECFEFF|F3E8FF|DCFCE7|FFEDD5|FEE2E2|F3F4F6|E5E7EB|16A34A|7C3AED|EA580C|DC2626)\)" \
  ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift \
  ios/Sanchr-iOS/Features/Settings/Presentation/SanchrModeCard.swift
```

Expected: zero results in `PrivacyView.swift` and `BlockedContactsView.swift`. `SanchrModeCard.swift` may still contain `0x111827` and `0x0F172A` — that's the intentional hero gradient, not a pastel.

- [ ] **Step 6: Verify `PrivacyView.swift` size target**

```bash
wc -l ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift
```

Expected: ≤ 300 lines. If above 300 the view still contains something that should have been extracted.

- [ ] **Step 7: Clean xcodebuild**

```bash
cd ios/Sanchr-iOS && xcodebuild clean build \
  -project Sanchr.xcodeproj \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -quiet 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. Zero new warnings.

- [ ] **Step 8: Tag the completion point**

```bash
git tag -a privacy-phase1-complete -m "Privacy Phase 1 hardening: gate struct in repo, cache cleared on logout, dead state removed, borders gone, dark theme fixed"
```

- [ ] **Step 9: Print summary**

```bash
git log --oneline -15
```

Confirm the 12 task commits are visible in order. Do not push — the user controls the push.

---

## Self-Review Checklist

After all 13 tasks land, the spec's 12 success criteria are satisfied:

1. Four `.overlay { .stroke }` borders removed — Task 11 steps 1-4.
2. Privacy screen renders correctly in dark mode — Task 12 step 7 manual check.
3. Last Seen, About, Disappearing Messages rows removed — Task 10.
4. `MessageRepositoryImpl.markAsRead / sendTypingIndicator / sendPresenceHeartbeat` consult `privacyGate.decide(...)` — Task 3 + Task 13 step 2 invariants.
5. `ChatDetailView`, `ChatDetailViewModel`, `RealtimeService` no longer contain `canSend*` checks — Task 7 + Task 13 step 3 grep.
6. `SessionService.clearSession()` resets `PrivacySettingsCache` — Task 5.
7. Cache tracks `profilePhotoVisibility`, `blockedUserIds`, supports `clear()` / `update(blockList:)` — Task 1.
8. Unit tests §4.1 (`MessagingPrivacyGateTests`), §4.2 (`SessionServicePrivacyClearTests`), §4.3 (extended `PrivacySettingsCacheTests`) pass — Tasks 1, 2, 5, 6.
9. Gate-wiring grep invariants in §4.4 pass — Task 13 step 2.
10. `xcodebuild` clean — Task 13 step 7.
11. `PrivacyView.swift` ≤ 300 LOC — Task 13 step 6.
12. `BlockedContactsView.swift` and `SanchrModeCard.swift` exist and are exercised — Tasks 8 and 9.
