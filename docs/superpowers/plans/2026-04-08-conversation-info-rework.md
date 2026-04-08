# Conversation Info Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder Media & Links section, collapse the duplicated Encryption rows, and make the global + per-chat Wallpaper / Theme picker actually work end-to-end inside `ConversationInfoView`.

**Architecture:** A new `ChatAppearanceService` (`@Observable`, `@MainActor`) on `DependencyContainer` owns the global ↔ per-chat merge. Per-chat overrides live in a new `chatAppearanceOverride` SQLCipher table with cascade-on-delete (sibling table, not new columns on `conversation` — keeps `ConversationRecord` untouched). A unified `WallpaperPainter` registry replaces the hand-rolled wallpaper arrays in `AppearanceView` and the private `WallpaperThemeView`. Two pre-existing bugs that block the global path get fixed in passing: the `SanchrTheme` env default returning fresh instances per read, and `.sanchrThemed()` never being applied at the app root. A new `SharedContentView` (Media / Links / Docs tabs, paginated) opens from a "View All" button on the inline media section.

**Tech Stack:** SwiftUI + GRDB (SQLCipher), `@Observable`, existing `MediaGalleryCoordinator` / `DocumentPreviewCoordinator` from the bubble-viewers feature, existing `LinkPreviewService`, no backend or proto changes.

**Spec:** `docs/superpowers/specs/2026-04-08-conversation-info-rework-design.md`

**Spec deviation noted upfront:** the spec proposed `ALTER TABLE conversation ADD COLUMN wallpaper_id / appearance_mode`. The plan instead introduces a sibling `chatAppearanceOverride` table because (a) it keeps the heavily-trafficked `ConversationRecord` Codable struct untouched, (b) it cascades naturally on conversation delete, and (c) it matches the existing pattern (`accessKeyEntry` is also a sibling table). The merge semantics, public Swift API, and behavior are identical.

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `SanchrShared/Models/ChatAppearance.swift` | `ChatAppearance` resolved value, `AppearanceOverride` optional pair |
| `SanchrShared/DesignSystem/WallpaperPainter.swift` | Wallpaper registry + `chatBackground(wallpaperId:)` modifier |
| `SanchrShared/DesignSystem/MediaCellOverlay.swift` | Reusable video play-badge + duration label (shared between recents strip + SharedContent media tab) |
| `Shared/Services/ChatAppearanceService.swift` | Resolver + global ↔ per-chat merge |
| `Features/Chats/Presentation/SharedContent/SharedContentView.swift` | Tabbed Media / Links / Docs screen |
| `Features/Chats/Presentation/SharedContent/SharedContentViewModel.swift` | Pagination + bucketization |
| `Tests/UnitTests/Features/Chats/ChatAppearanceServiceTests.swift` | Resolver merge + cache + override mutations |
| `Tests/UnitTests/Features/Chats/SharedContentViewModelTests.swift` | Bucketization + pagination cursor + link extraction |

### Modified files

| Path | Change |
|---|---|
| `SanchrShared/Persistence/DatabaseSchema.swift` | Register `v4_chat_appearance_overrides` migration adding the `chatAppearanceOverride` sibling table |
| `SanchrShared/Persistence/DatabaseRecords.swift` | New `ChatAppearanceOverrideRecord` GRDB record |
| `SanchrShared/Persistence/LocalDatabase.swift` | New `fetchAppearanceOverride` / `setAppearanceOverride` / `clearAppearanceOverride` methods + protocol entries |
| `App/SanchrApp.swift` | Single shared `SanchrTheme` instance, env injection, `.sanchrThemed()` at root, `@AppStorage` rehydration |
| `App/DependencyContainer.swift` | Expose `chatAppearance: ChatAppearanceService` |
| `Features/Chats/Presentation/ChatDetailView.swift` | Apply `.chatBackground` + `.preferredColorScheme` from resolved appearance, cache-warm in `.task` |
| `Features/Chats/Presentation/ConversationInfoView.swift` | Rewrite `mediaSection`; collapse `securitySection` to a single Encryption row; rewrite the private `WallpaperThemeView`; pass `conversation.id` to it |
| `Features/Settings/Presentation/AppearanceView.swift` | Wallpaper grid + theme cards write through `chatAppearance.setGlobal(...)`; read from `WallpaperPainter.allWallpapers` |
| `Features/Chats/Presentation/AttachmentPicker/AttachmentPickerRecentsStrip.swift` | Replace inline play badge + duration label with the shared `MediaCellOverlay` |
| `Tests/UnitTests/TestDoubles.swift` | Mock `LocalDatabase` conformance for the three new appearance-override methods |

### Files explicitly NOT touched

- `VerifySecurityCodeView` and any of its sub-views.
- Any view that already uses Liquid Glass APIs the user has added.
- Any backend / proto files.

---

## Task Breakdown

Tasks are grouped into seven phases. Every phase ends with a build + commit gate. Build verification command for **all** tasks unless stated otherwise:

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
  /opt/homebrew/bin/xcodegen generate 2>&1 | tail -1 && \
  xcodebuild -project Sanchr.xcodeproj -scheme Sanchr \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -3
```

Expected last line: `** BUILD SUCCEEDED **`. (`xcodegen generate` is needed when adding new files; skip it for in-place edits.)

---

## Phase 1 — Global theme + wallpaper plumbing fixes

Goal: make global dark mode and global wallpaper actually take effect on the chat detail screen, end-to-end. This phase is a prerequisite for everything else: it unblocks both the Settings screen behavior the user reported broken AND establishes `WallpaperPainter` as the single registry the per-chat picker depends on. No per-chat or override behavior yet.

### Task 1: `WallpaperPainter` registry + `chatBackground` modifier

**Files:**
- Create: `ios/Sanchr-iOS/SanchrShared/DesignSystem/WallpaperPainter.swift`

- [ ] **Step 1: Create the file with the full registry**

```swift
import SwiftUI

/// Single source of truth for chat wallpaper IDs and their visual
/// definitions. Both the global `AppearanceView` picker and the
/// per-chat `WallpaperThemeView` picker read from `allWallpapers` so
/// the two surfaces never drift.
public enum WallpaperPainter {
    public struct Wallpaper: Identifiable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let colors: [Color]
        public let isDark: Bool
    }

    public static let allWallpapers: [Wallpaper] = [
        .init(id: "default",     displayName: "Default",     colors: [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)], isDark: false),
        .init(id: "indigo_mist", displayName: "Indigo Mist", colors: [Color(hex: 0xEEF2FF), Color(hex: 0xE0E7FF)], isDark: false),
        .init(id: "cyan_air",    displayName: "Blue Air",    colors: [Color(hex: 0xECFEFF), Color(hex: 0xCFFAFE)], isDark: false),
        .init(id: "pink_sunset", displayName: "Pink Sunset", colors: [Color(hex: 0xFDF2F8), Color(hex: 0xFCE7F3)], isDark: false),
        .init(id: "green_field", displayName: "Green Field", colors: [Color(hex: 0xF0FDF4), Color(hex: 0xDCFCE7)], isDark: false),
        .init(id: "amber_glow",  displayName: "Amber Glow",  colors: [Color(hex: 0xFFFBEB), Color(hex: 0xFEF3C7)], isDark: false),
        .init(id: "dark_indigo", displayName: "Dark Indigo", colors: [Color(hex: 0x1E1B4B), Color(hex: 0x312E81)], isDark: true),
        .init(id: "midnight",    displayName: "Midnight",    colors: [Color(hex: 0x0F172A), Color(hex: 0x1E293B)], isDark: true),
        .init(id: "deep_blue",   displayName: "Deep Blue",   colors: [Color(hex: 0x1A1A2E), Color(hex: 0x16213E)], isDark: true),
    ]

    /// Returns the wallpaper matching `id`, or the default wallpaper as
    /// a graceful fallback if the id isn't in the registry.
    public static func wallpaper(for id: String) -> Wallpaper {
        allWallpapers.first(where: { $0.id == id }) ?? allWallpapers[0]
    }

    /// SwiftUI background view for the given wallpaper id. Always
    /// returns a `LinearGradient` because every wallpaper in the
    /// registry is gradient-based.
    public static func background(for id: String) -> some View {
        let wp = wallpaper(for: id)
        return LinearGradient(
            colors: wp.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// View modifier that paints a wallpaper as the background of a chat
/// surface. Ignores safe area so the gradient extends behind the nav
/// bar and home indicator.
public struct ChatBackgroundModifier: ViewModifier {
    let wallpaperId: String
    public init(wallpaperId: String) { self.wallpaperId = wallpaperId }
    public func body(content: Content) -> some View {
        content.background(WallpaperPainter.background(for: wallpaperId).ignoresSafeArea())
    }
}

public extension View {
    /// Paint a chat wallpaper behind this view. Use the wallpaper id
    /// from the global setting or per-chat override; unknown ids fall
    /// back to the default wallpaper via `WallpaperPainter.wallpaper(for:)`.
    func chatBackground(wallpaperId: String) -> some View {
        modifier(ChatBackgroundModifier(wallpaperId: wallpaperId))
    }
}
```

- [ ] **Step 2: Regenerate Xcode project so the new file is picked up**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && /opt/homebrew/bin/xcodegen generate
```

- [ ] **Step 3: Build to confirm SanchrShared compiles**

Run the standard build verification command (see header). Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add SanchrShared/DesignSystem/WallpaperPainter.swift Sanchr.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
feat(shared): add WallpaperPainter registry and chatBackground modifier

Single source of truth for chat wallpaper IDs and their gradient
definitions. Both AppearanceView (global) and WallpaperThemeView
(per-chat) will read from this registry so the two surfaces never
drift. Includes a chatBackground(wallpaperId:) modifier ChatDetailView
will use to actually paint the wallpaper for the first time.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Single shared `SanchrTheme` at the app root

**Files:**
- Modify: `ios/Sanchr-iOS/App/SanchrApp.swift:13-47`

- [ ] **Step 1: Add the `@AppStorage` rehydration var and the shared theme `@State`**

In `App/SanchrApp.swift`, locate the `struct SanchrApp: App` block (around line 13) and the `@State private var container = DependencyContainer()` line. Add immediately below:

```swift
    @State private var sanchrTheme = SanchrTheme()
    @AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.light.rawValue
```

- [ ] **Step 2: Inject the theme into the environment + apply `.sanchrThemed()` at the root**

Find the existing `RootView()` chain in `body` (around line 21):

```swift
            RootView()
                .environment(container)
                .environment(appRouter)
                .environment(container.syncState)
```

Replace with:

```swift
            RootView()
                .environment(container)
                .environment(appRouter)
                .environment(container.syncState)
                .environment(\.sanchrTheme, sanchrTheme)
                .sanchrThemed()
```

- [ ] **Step 3: Rehydrate the saved theme mode on first launch**

In the same `body`, find the existing `.task { ... }` (around line 32) and add a hydration step at the **start** of its closure body, before `do { try await container.connectGRPC() }`:

```swift
                .task {
                    if let saved = SanchrTheme.Mode(rawValue: storedThemeMode) {
                        sanchrTheme.mode = saved
                    }
                    do {
                        try await container.connectGRPC()
                    } catch {
                        SanchrLogger.network.error("Failed to connect gRPC channels: \(error.localizedDescription)")
                    }
                    // Wire PushManager after gRPC is connected (it needs notificationService)
                    await MainActor.run {
                        configurePushManager()
                    }
                }
```

- [ ] **Step 4: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`. The fix is invisible to the user yet because nothing reads `theme.mode` to flip wallpapers — that lands in Task 3 and Phase 2.

- [ ] **Step 5: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add App/SanchrApp.swift && \
git commit -m "$(cat <<'EOF'
fix(app): inject single shared SanchrTheme at root and apply sanchrThemed

Two pre-existing bugs blocking the global dark/light toggle:

1. EnvironmentKey.defaultValue = SanchrTheme() returned a fresh
   instance per environment read, so AppearanceView.theme.mode = .dark
   mutated an instance no other view ever saw.
2. The .sanchrThemed() ViewModifier (which applies
   .preferredColorScheme(theme.mode.colorScheme)) existed in
   SanchrShared/DesignSystem/Theme.swift but no view called it.

Fixed by holding ONE @State SanchrTheme at the SanchrApp root,
injecting via .environment(\.sanchrTheme,), and chaining
.sanchrThemed() on RootView. AppStorage("sanchr.themeMode")
rehydration runs once on app start so the user's last choice
survives launches.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `ChatDetailView` paints the wallpaper

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Add a `@Environment` reference to the settings view model**

The wallpaper id needs to come from somewhere. Phase 2 will introduce `ChatAppearanceService`, but for this task we read directly from `SettingsViewModel.chatWallpaper` so the global wallpaper renders immediately. Find the existing `@Environment` block at the top of `struct ChatDetailView: View` (around line 11):

```swift
struct ChatDetailView: View {
    let conversation: Conversation

    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ChatDetailViewModel()
```

Add immediately below `@Environment(\.dismiss)`:

```swift
    @Environment(\.sanchrTheme) private var sanchrTheme
```

- [ ] **Step 2: Apply `.chatBackground(wallpaperId:)` to the chat detail body**

Find the outer `var body: some View {` of `ChatDetailView` (around line 39) and the closing of its main `VStack`. The current end of `body` looks like:

```swift
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }
```

(The exact tail depends on the file's current state — read the file first if uncertain.) Apply the modifier as the **first** modifier on the outer `VStack(spacing: 0) { ... }` so the gradient sits behind everything:

Locate the `var body: some View { ... VStack(spacing: 0) { ... } ... }` open and add:

```swift
    var body: some View {
        let wallpaperId = container.settingsViewModel.chatWallpaper.isEmpty
            ? "default"
            : container.settingsViewModel.chatWallpaper
        VStack(spacing: 0) {
            // ...existing body unchanged...
        }
        .chatBackground(wallpaperId: wallpaperId)
        // ...all other existing modifiers unchanged below...
    }
```

The `.chatBackground` modifier MUST be applied **before** any `.background(...)` or material that the existing body sets — putting it first inside the modifier chain after the `VStack` ensures the gradient is the deepest layer. Do NOT wrap it inside an existing `.background(...)`; chain it as a sibling modifier.

**IMPORTANT:** if `container.settingsViewModel` doesn't exist on `DependencyContainer`, check whether the project already constructs `SettingsViewModel` somewhere reachable from `container`. Grep:

```bash
grep -n "SettingsViewModel" App/DependencyContainer.swift
```

If `SettingsViewModel` isn't on the container today, add a `lazy var settingsViewModel = SettingsViewModel()` in `App/DependencyContainer.swift` next to the other `lazy var` declarations and use it. (`SettingsViewModel` exists at `Features/Settings/Presentation/SettingsViewModel.swift`.)

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual sanity (no commit yet)**

Run on device or simulator: open any chat. The chat background should be the default light gradient (not the surface color it was before). Open Settings → Appearance → pick a different wallpaper from the existing picker. Pop back to the chat: you should see the new wallpaper. (If not, the consumer wiring is wrong — debug before continuing.)

- [ ] **Step 5: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailView.swift App/DependencyContainer.swift && \
git commit -m "$(cat <<'EOF'
fix(chats): paint global chat wallpaper in ChatDetailView

The chatWallpaper field on SettingsViewModel was set + synced to the
backend by AppearanceView but no chat-side view ever consumed it.
ChatDetailView now reads it through the container and applies the
new chatBackground(wallpaperId:) modifier from WallpaperPainter as
the first modifier on its outer VStack. Selecting a wallpaper in
Settings → Appearance now visibly changes every chat the next time
the chat detail is shown.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 1** — the global Dark/Light toggle in Settings → Appearance now actually flips the rendered scheme, and the global wallpaper picker actually paints chat backgrounds. Per-chat overrides land in Phase 2.

---

## Phase 2 — `ChatAppearanceService` resolver + DB plumbing

Goal: per-chat overrides land in SQLCipher, the resolver merge logic ships behind the protocol, and `ChatDetailView` reads from the resolver instead of straight from `SettingsViewModel`. No UI for the per-chat picker yet — that's Phase 3.

### Task 4: New `chatAppearanceOverride` table migration

**Files:**
- Modify: `ios/Sanchr-iOS/SanchrShared/Persistence/DatabaseSchema.swift:148-149`

- [ ] **Step 1: Register the migration**

Open `SanchrShared/Persistence/DatabaseSchema.swift`. Find the existing `migrator.registerMigration("v3_access_key_entries") { db in ... }` block (line 126) and the `return migrator` line that follows it (line 149). Insert the new migration **between** the v3 block's closing brace and `return migrator`:

```swift
        migrator.registerMigration("v4_chat_appearance_overrides") { db in
            try db.create(table: "chatAppearanceOverride", ifNotExists: true) { t in
                t.primaryKey("conversationId", .text).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("wallpaperId", .text)
                t.column("appearanceMode", .text)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        return migrator
```

- [ ] **Step 2: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add SanchrShared/Persistence/DatabaseSchema.swift && \
git commit -m "$(cat <<'EOF'
feat(persistence): add v4_chat_appearance_overrides migration

New chatAppearanceOverride table keyed by conversationId with
nullable wallpaperId + appearanceMode columns. Sibling table
(not new columns on conversation) keeps ConversationRecord
untouched and gets cascade-on-delete for free via the FK to
conversation.id.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `AppearanceOverride` + `ChatAppearance` value types in SanchrShared

**Files:**
- Create: `ios/Sanchr-iOS/SanchrShared/Models/ChatAppearance.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Resolved appearance for a chat — the merge result of global
/// settings and any per-chat override row. Both fields are non-nil:
/// the resolver fills in defaults from global state when an override
/// is missing.
public struct ChatAppearance: Equatable, Sendable {
    public let wallpaperId: String
    public let appearanceMode: SanchrTheme.Mode
    public let isPerChatOverride: Bool

    public init(
        wallpaperId: String,
        appearanceMode: SanchrTheme.Mode,
        isPerChatOverride: Bool
    ) {
        self.wallpaperId = wallpaperId
        self.appearanceMode = appearanceMode
        self.isPerChatOverride = isPerChatOverride
    }
}

/// Optional pair persisted in the chatAppearanceOverride table.
/// Either field may be nil; nil means "fall back to global". An
/// override with both fields nil is meaningless and `setOverride`
/// short-circuits to a delete instead of writing the row.
public struct AppearanceOverride: Equatable, Sendable {
    public let wallpaperId: String?
    public let appearanceMode: SanchrTheme.Mode?

    public init(wallpaperId: String?, appearanceMode: SanchrTheme.Mode?) {
        self.wallpaperId = wallpaperId
        self.appearanceMode = appearanceMode
    }
}
```

- [ ] **Step 2: Regenerate the project + build**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && /opt/homebrew/bin/xcodegen generate
```

Then run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add SanchrShared/Models/ChatAppearance.swift Sanchr.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
feat(shared): add ChatAppearance + AppearanceOverride value types

ChatAppearance carries the resolved (always non-nil) wallpaper id
+ mode + an isPerChatOverride flag the picker uses to render the
scope banner. AppearanceOverride is the optional pair stored in
the new chatAppearanceOverride table. Equatable + Sendable so the
service that holds them can be @Observable.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `ChatAppearanceOverrideRecord` + `LocalDatabase` methods

**Files:**
- Modify: `ios/Sanchr-iOS/SanchrShared/Persistence/DatabaseRecords.swift`
- Modify: `ios/Sanchr-iOS/SanchrShared/Persistence/LocalDatabase.swift`
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/TestDoubles.swift`

- [ ] **Step 1: Add the GRDB record at the bottom of `DatabaseRecords.swift`**

```swift
// MARK: - Chat Appearance Overrides

public struct ChatAppearanceOverrideRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "chatAppearanceOverride"

    public var conversationId: String
    public var wallpaperId: String?
    public var appearanceMode: String?
    public var updatedAt: Date

    public init(
        conversationId: String,
        wallpaperId: String?,
        appearanceMode: String?,
        updatedAt: Date
    ) {
        self.conversationId = conversationId
        self.wallpaperId = wallpaperId
        self.appearanceMode = appearanceMode
        self.updatedAt = updatedAt
    }

    public func toDomain() -> AppearanceOverride {
        AppearanceOverride(
            wallpaperId: wallpaperId,
            appearanceMode: appearanceMode.flatMap(SanchrTheme.Mode.init(rawValue:))
        )
    }

    public static func from(
        conversationId: String,
        override: AppearanceOverride,
        now: Date = Date()
    ) -> ChatAppearanceOverrideRecord {
        ChatAppearanceOverrideRecord(
            conversationId: conversationId,
            wallpaperId: override.wallpaperId,
            appearanceMode: override.appearanceMode?.rawValue,
            updatedAt: now
        )
    }
}
```

- [ ] **Step 2: Add the protocol entries to `LocalDatabaseProtocol`**

In `SanchrShared/Persistence/LocalDatabase.swift`, find the `protocol LocalDatabaseProtocol: AnyObject, Sendable {` block (line 5). After the `// MARK: - Access Keys (Media Forward Secrecy)` block (around line 43) and before the `// MARK: - Lifecycle` block (line 45), add:

```swift
    // MARK: - Chat Appearance Overrides

    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride?
    func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws
    func clearAppearanceOverride(conversationId: String) async throws
```

- [ ] **Step 3: Implement the three methods on `LocalDatabase`**

In the same file, find the existing `purgeAccessKeyEntries` / `deleteAllAccessKeyEntries` block (a good neighbor location). After it, add:

```swift
    // MARK: - Chat Appearance Overrides

    public func fetchAppearanceOverride(
        conversationId: String
    ) async throws -> AppearanceOverride? {
        try await dbPool.read { db in
            try ChatAppearanceOverrideRecord
                .fetchOne(db, key: conversationId)?
                .toDomain()
        }
    }

    public func setAppearanceOverride(
        _ override: AppearanceOverride,
        for conversationId: String
    ) async throws {
        // No-op-erasure: an all-nil override is meaningless. Delete the
        // row instead of persisting an empty pair so `fetchAppearanceOverride`
        // returns nil and the resolver falls back cleanly to global.
        if override.wallpaperId == nil && override.appearanceMode == nil {
            try await clearAppearanceOverride(conversationId: conversationId)
            return
        }
        try await dbPool.write { db in
            let record = ChatAppearanceOverrideRecord.from(
                conversationId: conversationId,
                override: override
            )
            try record.save(db, onConflict: Database.ConflictResolution.replace)
        }
    }

    public func clearAppearanceOverride(conversationId: String) async throws {
        _ = try await dbPool.write { db in
            try ChatAppearanceOverrideRecord
                .filter(Column("conversationId") == conversationId)
                .deleteAll(db)
        }
    }
```

- [ ] **Step 4: Add stubs to the failing-mock at the bottom of the same file**

The bottom of `LocalDatabase.swift` (around line 1116) has a `class FailingLocalDatabase: LocalDatabaseProtocol` that throws on every method. Add the three new methods to keep the protocol conformance compiling:

```swift
    public func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { throw error }
    public func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws { throw error }
    public func clearAppearanceOverride(conversationId: String) async throws { throw error }
```

- [ ] **Step 5: Add stubs to `MockLocalDatabase` in `Tests/UnitTests/TestDoubles.swift`**

Open `Tests/UnitTests/TestDoubles.swift` and locate `class MockLocalDatabase: LocalDatabaseProtocol` (grep `MockLocalDatabase` to confirm the line). Add the three methods. The mock stores overrides in an in-memory dictionary so tests can assert against the persisted state:

```swift
    var appearanceOverrides: [String: AppearanceOverride] = [:]

    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? {
        appearanceOverrides[conversationId]
    }

    func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws {
        if override.wallpaperId == nil && override.appearanceMode == nil {
            appearanceOverrides.removeValue(forKey: conversationId)
        } else {
            appearanceOverrides[conversationId] = override
        }
    }

    func clearAppearanceOverride(conversationId: String) async throws {
        appearanceOverrides.removeValue(forKey: conversationId)
    }
```

- [ ] **Step 6: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add SanchrShared/Persistence/DatabaseRecords.swift \
        SanchrShared/Persistence/LocalDatabase.swift \
        Tests/UnitTests/TestDoubles.swift && \
git commit -m "$(cat <<'EOF'
feat(persistence): persist chat appearance overrides

Adds ChatAppearanceOverrideRecord (GRDB Codable+Persistable) and
LocalDatabase fetch/set/clear methods plus the protocol entries.
setAppearanceOverride short-circuits to delete when both fields
are nil so an all-nil override never gets persisted. MockLocalDatabase
gets a matching in-memory store + the same short-circuit so unit
tests against the resolver can assert against post-mutation state.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `ChatAppearanceService` resolver + tests

**Files:**
- Create: `ios/Sanchr-iOS/Shared/Services/ChatAppearanceService.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/ChatAppearanceServiceTests.swift`
- Modify: `ios/Sanchr-iOS/App/DependencyContainer.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/UnitTests/Features/Chats/ChatAppearanceServiceTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatAppearanceServiceTests: XCTestCase {

    func test_effectiveAppearance_returnsGlobalWhenNoOverride() async {
        let service = makeService(globalWallpaperId: "amber_glow", globalMode: .light)
        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "amber_glow")
        XCTAssertEqual(appearance.appearanceMode, .light)
        XCTAssertFalse(appearance.isPerChatOverride)
    }

    func test_effectiveAppearance_returnsOverrideWhenPresent() async {
        let db = MockLocalDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "midnight",
            appearanceMode: .dark
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)
        await service.loadOverride(conversationId: "conv-1")

        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "midnight")
        XCTAssertEqual(appearance.appearanceMode, .dark)
        XCTAssertTrue(appearance.isPerChatOverride)
    }

    func test_effectiveAppearance_mixesOverrideWallpaperWithGlobalMode() async {
        let db = MockLocalDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "deep_blue",
            appearanceMode: nil
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)
        await service.loadOverride(conversationId: "conv-1")

        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "deep_blue")
        XCTAssertEqual(appearance.appearanceMode, .light) // global
        XCTAssertTrue(appearance.isPerChatOverride)
    }

    func test_setOverride_persistsAndRefreshesCache() async {
        let db = MockLocalDatabase()
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)

        await service.setOverride(
            conversationId: "conv-1",
            wallpaperId: "midnight",
            appearanceMode: .dark
        )

        XCTAssertEqual(db.appearanceOverrides["conv-1"]?.wallpaperId, "midnight")
        XCTAssertEqual(service.effectiveAppearance(for: "conv-1").wallpaperId, "midnight")
    }

    func test_setOverride_withBothNilClearsRow() async {
        let db = MockLocalDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "midnight",
            appearanceMode: .dark
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)
        await service.loadOverride(conversationId: "conv-1")

        await service.setOverride(
            conversationId: "conv-1",
            wallpaperId: nil,
            appearanceMode: nil
        )

        XCTAssertNil(db.appearanceOverrides["conv-1"])
        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "default")
        XCTAssertFalse(appearance.isPerChatOverride)
    }

    func test_setGlobal_mirrorsToSettingsViewModelAndTheme() async {
        let theme = SanchrTheme()
        let settingsVM = SettingsViewModel()
        let service = makeService(
            theme: theme,
            settingsViewModel: settingsVM,
            globalWallpaperId: "default",
            globalMode: .light
        )

        service.setGlobal(wallpaperId: "midnight", appearanceMode: .dark)

        XCTAssertEqual(service.globalWallpaperId, "midnight")
        XCTAssertEqual(service.globalMode, .dark)
        XCTAssertEqual(settingsVM.chatWallpaper, "midnight")
        XCTAssertEqual(theme.mode, .dark)
    }

    func test_loadOverride_isIdempotent() async {
        let db = MockLocalDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "midnight",
            appearanceMode: .dark
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)

        await service.loadOverride(conversationId: "conv-1")
        // Mutate the DB out from under the service — second load should NOT
        // refresh the cache (idempotent within the lifetime of the cache).
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "amber_glow",
            appearanceMode: .light
        )
        await service.loadOverride(conversationId: "conv-1")

        XCTAssertEqual(service.effectiveAppearance(for: "conv-1").wallpaperId, "midnight")
    }

    // MARK: - Builders

    private func makeService(
        localDatabase: LocalDatabaseProtocol = MockLocalDatabase(),
        theme: SanchrTheme = SanchrTheme(),
        settingsViewModel: SettingsViewModel = SettingsViewModel(),
        globalWallpaperId: String,
        globalMode: SanchrTheme.Mode
    ) -> ChatAppearanceService {
        settingsViewModel.chatWallpaper = globalWallpaperId
        theme.mode = globalMode
        return ChatAppearanceService(
            localDatabase: localDatabase,
            theme: theme,
            settingsViewModel: settingsViewModel
        )
    }
}
```

- [ ] **Step 2: Run tests, confirm they fail to compile**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | grep "error:" | head
```

Expected: errors like `'ChatAppearanceService' not found in scope`.

(If the simulator NIO build is still broken from prior phases — see project context — fall back to a build-only check for the main target after Step 4.)

- [ ] **Step 3: Create `ChatAppearanceService.swift`**

```swift
import Foundation
import SanchrShared

/// Single source of truth for the global ↔ per-chat wallpaper + theme
/// merge. View code reads `effectiveAppearance(for:)` and writes through
/// `setOverride` (per-chat) or `setGlobal` (Settings → Appearance).
///
/// `@Observable` so any view that calls `effectiveAppearance(for:)`
/// redraws automatically when either the override cache or the global
/// slot mutates. The override cache is hydrated on demand via
/// `loadOverride(conversationId:)` which `ChatDetailView.task` calls
/// before first paint to avoid a flash from global → override.
@Observable
@MainActor
public final class ChatAppearanceService {
    public var globalWallpaperId: String
    public var globalMode: SanchrTheme.Mode

    private var overrides: [String: AppearanceOverride] = [:]
    private var loadedConversationIds: Set<String> = []

    private let localDatabase: LocalDatabaseProtocol
    private let theme: SanchrTheme
    private let settingsViewModel: SettingsViewModel

    public init(
        localDatabase: LocalDatabaseProtocol,
        theme: SanchrTheme,
        settingsViewModel: SettingsViewModel
    ) {
        self.localDatabase = localDatabase
        self.theme = theme
        self.settingsViewModel = settingsViewModel
        self.globalWallpaperId = settingsViewModel.chatWallpaper.isEmpty
            ? "default"
            : settingsViewModel.chatWallpaper
        self.globalMode = theme.mode
    }

    /// Resolution: per-chat override fields beat global; nil falls back.
    public func effectiveAppearance(for conversationId: String) -> ChatAppearance {
        let override = overrides[conversationId]
        return ChatAppearance(
            wallpaperId: override?.wallpaperId ?? globalWallpaperId,
            appearanceMode: override?.appearanceMode ?? globalMode,
            isPerChatOverride: override != nil
        )
    }

    /// Hydrate the override cache from the local database. Idempotent —
    /// the second call for the same conversationId is a no-op so external
    /// DB mutations don't sneak in mid-session.
    public func loadOverride(conversationId: String) async {
        guard !loadedConversationIds.contains(conversationId) else { return }
        loadedConversationIds.insert(conversationId)
        if let row = try? await localDatabase.fetchAppearanceOverride(conversationId: conversationId) {
            overrides[conversationId] = row
        }
    }

    /// Per-chat write. nil + nil clears the row entirely.
    public func setOverride(
        conversationId: String,
        wallpaperId: String?,
        appearanceMode: SanchrTheme.Mode?
    ) async {
        if wallpaperId == nil && appearanceMode == nil {
            try? await localDatabase.clearAppearanceOverride(conversationId: conversationId)
            overrides.removeValue(forKey: conversationId)
            loadedConversationIds.insert(conversationId)
            return
        }
        let override = AppearanceOverride(
            wallpaperId: wallpaperId,
            appearanceMode: appearanceMode
        )
        try? await localDatabase.setAppearanceOverride(override, for: conversationId)
        overrides[conversationId] = override
        loadedConversationIds.insert(conversationId)
    }

    /// Global write. Mirrors to SettingsViewModel + SanchrTheme so the
    /// existing backend sync paths keep working unchanged.
    public func setGlobal(
        wallpaperId: String?,
        appearanceMode: SanchrTheme.Mode?
    ) {
        if let wallpaperId {
            globalWallpaperId = wallpaperId
            settingsViewModel.chatWallpaper = wallpaperId
        }
        if let appearanceMode {
            globalMode = appearanceMode
            theme.mode = appearanceMode
        }
    }
}
```

- [ ] **Step 4: Wire onto `DependencyContainer`**

In `App/DependencyContainer.swift`, find the existing `lazy var sessionService` block (around line 200). Add **after** the section where both `theme` and `settingsViewModel` are reachable. If `settingsViewModel` was added in Phase 1 Task 3, reuse it. If not, add `lazy var settingsViewModel = SettingsViewModel()` first. Then:

```swift
    /// Resolves the wallpaper + theme for any chat from the global
    /// settings + per-chat override store. Owned at container scope so
    /// the @Observable propagation works for every chat-detail / picker
    /// surface that reads from it.
    @ObservationIgnored lazy var chatAppearance: ChatAppearanceService = {
        let theme = (try? environment.sanchrTheme) ?? SanchrTheme()
        return ChatAppearanceService(
            localDatabase: localDatabase,
            theme: theme,
            settingsViewModel: settingsViewModel
        )
    }()
```

**IMPORTANT:** `DependencyContainer` cannot read `@Environment` because it isn't a SwiftUI view. The `theme` parameter must be the same instance the SanchrApp root holds. The cleanest fix: pass it down explicitly. Replace the closure above with:

```swift
    @ObservationIgnored lazy var chatAppearance: ChatAppearanceService = ChatAppearanceService(
        localDatabase: localDatabase,
        theme: sharedTheme,
        settingsViewModel: settingsViewModel
    )

    /// Held by SanchrApp at the @State level and passed to the container
    /// so the resolver can mirror global theme writes to the same instance
    /// the root view binds via @Environment(\.sanchrTheme,).
    var sharedTheme: SanchrTheme = SanchrTheme()
```

In `App/SanchrApp.swift`, after the existing `@State private var sanchrTheme = SanchrTheme()` line from Phase 1 Task 2, add a **single** assignment in `body`'s `.task` (place it BEFORE the existing AppStorage rehydration block):

```swift
                .task {
                    container.sharedTheme = sanchrTheme
                    if let saved = SanchrTheme.Mode(rawValue: storedThemeMode) {
                        sanchrTheme.mode = saved
                    }
                    // ...rest of existing .task body unchanged
                }
```

That single assignment makes `container.chatAppearance.theme` (the resolver's mirror target) and `sanchrTheme` (the SwiftUI environment instance) the same `SanchrTheme` reference. Note that this only works because the resolver's `theme` is captured at `lazy var` initialization — so we must access `container.sharedTheme = sanchrTheme` BEFORE anything else reads `container.chatAppearance`. The `.task` runs once at app start before any chat detail screen is opened.

- [ ] **Step 5: Run the tests, confirm pass**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/ChatAppearanceServiceTests 2>&1 | tail -10
```

Expected: all 7 tests pass. If the simulator NIO build is broken, fall back to running the build-only check on the main target — the unit tests will be exercised when the sim NIO issue clears.

- [ ] **Step 6: Build the main target**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Shared/Services/ChatAppearanceService.swift \
        App/DependencyContainer.swift \
        App/SanchrApp.swift \
        Tests/UnitTests/Features/Chats/ChatAppearanceServiceTests.swift \
        Sanchr.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
feat(chats): add ChatAppearanceService resolver + container plumbing

@Observable @MainActor service that owns the global ↔ per-chat
wallpaper + theme merge. effectiveAppearance(for:) returns the
resolved (always non-nil) ChatAppearance with isPerChatOverride
flag for the picker's scope banner. setOverride short-circuits to
clear when both fields are nil. setGlobal mirrors to SettingsViewModel
+ SanchrTheme so the existing backend sync stays untouched.

DependencyContainer holds it as a @ObservationIgnored lazy var.
The shared SanchrTheme reference is passed down from SanchrApp via
container.sharedTheme = sanchrTheme inside the root .task so the
resolver and the SwiftUI environment mutate the same instance.

Seven unit tests cover: empty override falls back to global, override
takes precedence, mixed nil-field merge, mutation persists +
refreshes cache, all-nil delete, setGlobal mirrors, loadOverride
idempotency.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `ChatDetailView` reads from the resolver

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Replace the direct `SettingsViewModel.chatWallpaper` read with the resolver call**

Find the `var body: some View {` block from Phase 1 Task 3 that begins:

```swift
    var body: some View {
        let wallpaperId = container.settingsViewModel.chatWallpaper.isEmpty
            ? "default"
            : container.settingsViewModel.chatWallpaper
        VStack(spacing: 0) {
```

Replace with:

```swift
    var body: some View {
        let appearance = container.chatAppearance.effectiveAppearance(for: conversation.id)
        VStack(spacing: 0) {
```

Then update the modifier chain on the outer `VStack`. The Phase 1 chain ended with `.chatBackground(wallpaperId: wallpaperId)`. Replace with both the wallpaper modifier and a `.preferredColorScheme(...)` for per-chat dark mode:

```swift
        .chatBackground(wallpaperId: appearance.wallpaperId)
        .preferredColorScheme(appearance.appearanceMode.colorScheme)
```

The `.preferredColorScheme` call wins inside this view subtree even though the app root sets a global one — perfect for per-chat dark mode.

- [ ] **Step 2: Cache-warm the override in `.task`**

Find the existing `.task { ... }` block on the body (around line 200) — the one that calls `viewModel.loadMessages(...)`. Add at the **start** of its closure:

```swift
        .task {
            await container.chatAppearance.loadOverride(conversationId: conversation.id)
            await viewModel.loadMessages(
                conversationId: conversation.id,
                messageRepository: container.messageRepository
            )
        }
```

Without the warming step, the first paint reads `effectiveAppearance` with an empty cache (= global state), then the override loads asynchronously and the chat flickers from global wallpaper to override wallpaper. Cache-warming before the first message load avoids the flicker.

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`. (Behavior is unchanged so far because no per-chat override exists for any chat — the picker rewrite that creates them is Phase 3.)

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): ChatDetailView reads wallpaper + theme from resolver

Replaces the direct container.settingsViewModel.chatWallpaper read
with container.chatAppearance.effectiveAppearance(for: conversation.id)
so per-chat overrides take effect once the picker writes them in
Phase 3. .preferredColorScheme(appearance.appearanceMode.colorScheme)
is applied alongside .chatBackground so per-chat dark mode flips the
nav bar tint. The chat detail .task now warms the resolver cache
before loading messages to avoid a global → override flash on first
paint.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 2** — per-chat overrides are persisted and read end-to-end. Still no UI to create them — that's Phase 3.

---

## Phase 3 — Conversation Info wallpaper & theme picker rewrite + AppearanceView migration

Goal: rewrite the private `WallpaperThemeView` inside `ConversationInfoView.swift` to actually persist per-chat overrides, plus migrate the global Settings `AppearanceView` to write through `chatAppearance.setGlobal(...)`.

### Task 9: Rewrite the private `WallpaperThemeView` for per-chat overrides

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ConversationInfoView.swift:74-80, 1140-1253`

- [ ] **Step 1: Update the navigation site to pass `conversation.id`**

In `ConversationInfoView.swift` find the existing navigation destination (line 74-76):

```swift
        .navigationDestination(isPresented: $showWallpaper) {
            WallpaperThemeView()
        }
```

Replace with:

```swift
        .navigationDestination(isPresented: $showWallpaper) {
            WallpaperThemeView(conversationId: conversation.id)
        }
```

- [ ] **Step 2: Replace the body of the private `WallpaperThemeView` struct**

Find `private struct WallpaperThemeView: View {` (line 1142). Replace the entire struct definition (lines 1142-1253) with:

```swift
private struct WallpaperThemeView: View {
    let conversationId: String

    @Environment(DependencyContainer.self) private var container
    @State private var selectedWallpaperId: String = "default"
    @State private var darkMode: Bool = false
    @State private var hasOverride: Bool = false
    @State private var isLoading: Bool = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                scopeBanner
                darkModeToggleRow
                wallpaperGrid
                if hasOverride {
                    resetToGlobalButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Wallpaper & Theme")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await container.chatAppearance.loadOverride(conversationId: conversationId)
            let appearance = container.chatAppearance.effectiveAppearance(for: conversationId)
            selectedWallpaperId = appearance.wallpaperId
            darkMode = (appearance.appearanceMode == .dark)
            hasOverride = appearance.isPerChatOverride
            isLoading = false
        }
    }

    @ViewBuilder
    private var scopeBanner: some View {
        let copy = hasOverride
            ? "Applied to this chat only — overrides global"
            : "Inheriting global appearance"
        Text(copy)
            .font(SanchrTypography.captionSmall)
            .foregroundColor(SanchrExportColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SanchrExportColors.surfaceSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var darkModeToggleRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceSoft)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: darkMode ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrColors.primary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Dark Mode")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Use dark theme for this chat only")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { darkMode },
                set: { newValue in
                    darkMode = newValue
                    autoSwitchWallpaperForMode(newValue)
                    Task { await applyOverride() }
                }
            ))
            .labelsHidden()
            .tint(.sanchrPrimary)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var wallpaperGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chat Wallpaper")
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.semibold)
                .foregroundColor(SanchrExportColors.textPrimary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                ForEach(WallpaperPainter.allWallpapers) { wp in
                    WallpaperPainter.background(for: wp.id)
                        .aspectRatio(0.7, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if selectedWallpaperId == wp.id {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SanchrColors.primary, lineWidth: 3)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(SanchrColors.primary)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedWallpaperId = wp.id
                                darkMode = wp.isDark
                            }
                            Task { await applyOverride() }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var resetToGlobalButton: some View {
        Button {
            Task { await resetToGlobal() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                Text("Reset to Global")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
            }
            .foregroundColor(SanchrColors.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(SanchrColors.primary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutations

    private func applyOverride() async {
        await container.chatAppearance.setOverride(
            conversationId: conversationId,
            wallpaperId: selectedWallpaperId,
            appearanceMode: darkMode ? .dark : .light
        )
        hasOverride = true
    }

    private func resetToGlobal() async {
        await container.chatAppearance.setOverride(
            conversationId: conversationId,
            wallpaperId: nil,
            appearanceMode: nil
        )
        let appearance = container.chatAppearance.effectiveAppearance(for: conversationId)
        selectedWallpaperId = appearance.wallpaperId
        darkMode = (appearance.appearanceMode == .dark)
        hasOverride = false
    }

    /// When the user toggles dark mode on/off, switch the selected
    /// wallpaper to the first matching-tone wallpaper from the registry
    /// IF the current selection doesn't already match. Avoids the
    /// incoherent "dark mode on, but light wallpaper selected" state
    /// while preserving the user's explicit pick when they pick it
    /// after toggling.
    private func autoSwitchWallpaperForMode(_ isDark: Bool) {
        let currentWp = WallpaperPainter.wallpaper(for: selectedWallpaperId)
        guard currentWp.isDark != isDark else { return }
        let candidates = WallpaperPainter.allWallpapers.filter { $0.isDark == isDark }
        if let first = candidates.first {
            selectedWallpaperId = first.id
        }
    }
}
```

- [ ] **Step 3: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ConversationInfoView.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): rewrite per-chat WallpaperThemeView for real persistence

The private WallpaperThemeView inside ConversationInfoView used to
hold local-only @State (darkMode = false, selectedWallpaper = 0)
that nothing read or persisted. Replaced with a real picker bound
to ChatAppearanceService:

- Reads effectiveAppearance(for: conversationId) on appear
- Scope banner shows whether the chat is overriding or inheriting
- Wallpaper grid sourced from WallpaperPainter.allWallpapers
- Tap → withAnimation { selectedWallpaperId = wp.id; darkMode = wp.isDark }
  → applyOverride() → setOverride on the resolver
- Dark Mode toggle calls autoSwitchWallpaperForMode so a toggle to
  ON swaps to the first dark wallpaper unless the current is already
  dark, mirror for OFF
- Reset to Global button clears the override row + re-syncs the
  selection to global state
- Visible only when an override exists

The destination init signature changes from init() to
init(conversationId: String); the single navigationDestination call
site is updated to pass conversation.id.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Migrate `AppearanceView` to write through `chatAppearance.setGlobal`

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Settings/Presentation/AppearanceView.swift`

- [ ] **Step 1: Add the container reference**

At the top of `struct AppearanceView: View`, the existing `@Environment(DependencyContainer.self) private var container` already exists (line 8). No new env injection needed.

- [ ] **Step 2: Replace the hand-rolled `wallpaperOptions` array**

Find the `private let wallpaperOptions: [(String, String)] = [...]` block (lines 26-32). **Delete** the entire `let wallpaperOptions` declaration. The grid will iterate over `WallpaperPainter.allWallpapers` instead.

- [ ] **Step 3: Update the wallpaper grid to read from the registry**

Find the `ForEach(wallpaperOptions, id: \.1) { name, value in` block (line 196). Replace its body with the registry-driven version. The exact replacement (locate the surrounding `LazyVGrid` and replace the entire ForEach):

```swift
                ForEach(WallpaperPainter.allWallpapers) { wp in
                    Button {
                        viewModel.chatWallpaper = wp.id
                        container.chatAppearance.setGlobal(
                            wallpaperId: wp.id,
                            appearanceMode: nil
                        )
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    } label: {
                        WallpaperPainter.background(for: wp.id)
                            .aspectRatio(0.7, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                if viewModel.chatWallpaper == wp.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(SanchrColors.primary)
                                }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        viewModel.chatWallpaper == wp.id
                                            ? SanchrColors.primary
                                            : Color(hex: 0xE5E7EB),
                                        lineWidth: viewModel.chatWallpaper == wp.id ? 2 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
```

The display name from `WallpaperPainter.Wallpaper.displayName` is intentionally not shown under the swatch in this layout — matches the existing AppearanceView grid which doesn't show names either.

- [ ] **Step 4: Update the theme cards to call `setGlobal` for the mode**

Find the existing theme button (line 81-86). Replace its action body:

```swift
                    Button {
                        theme.mode = mode
                        storedThemeMode = mode.rawValue
                        viewModel.theme = mode.rawValue
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    } label: {
```

with:

```swift
                    Button {
                        theme.mode = mode
                        storedThemeMode = mode.rawValue
                        viewModel.theme = mode.rawValue
                        container.chatAppearance.setGlobal(
                            wallpaperId: nil,
                            appearanceMode: mode
                        )
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    } label: {
```

The two existing writes (`theme.mode = mode` and `viewModel.theme = mode.rawValue`) stay as-is — `setGlobal` is additive. The resolver mirrors to the same `theme` instance, which is now genuinely shared across the app per Phase 1 Task 2.

- [ ] **Step 5: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Settings/Presentation/AppearanceView.swift && \
git commit -m "$(cat <<'EOF'
refactor(settings): AppearanceView reads from WallpaperPainter, writes
through chatAppearance.setGlobal

Drops the hand-rolled wallpaperOptions array and iterates over
WallpaperPainter.allWallpapers — single source of truth shared with
the per-chat picker. Both the wallpaper grid and the theme cards
now call container.chatAppearance.setGlobal(...) in addition to the
existing viewModel + theme + storedThemeMode + AppStorage writes.
The existing backend sync via debouncedSync(settingsDataSource:) is
preserved unchanged because setGlobal mirrors the wallpaper id back
into viewModel.chatWallpaper.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 3** — global + per-chat wallpaper / theme picker is fully wired. Tap test on device: open a chat → Conversation Info → Wallpaper & Theme → pick a dark wallpaper → pop back. The chat detail should show the dark wallpaper, the rest of the app stays light.

---

## Phase 4 — Encryption row collapse

Goal: delete the duplicate `Encryption Keys` row in `ConversationInfoView.securitySection`.

### Task 11: Collapse the two security NavigationLinks into one Encryption row

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ConversationInfoView.swift:283-308`

- [ ] **Step 1: Replace the two-row block with a single Encryption row**

Find the `private var securitySection: some View {` body in `ConversationInfoView.swift` (line 275). The existing two NavigationLinks span lines 283-308. Replace the **whole** two-link block with a single one:

```swift
            NavigationLink {
                VerifySecurityCodeView(conversation: conversation)
            } label: {
                settingsRow(
                    icon: "lock.shield.fill",
                    iconBg: SanchrColors.primary.opacity(0.1),
                    iconColor: SanchrColors.primary,
                    title: "Encryption",
                    subtitle: "Verify security code and view keys"
                )
            }
            .buttonStyle(.plain)
```

Verify by grepping that only one `VerifySecurityCodeView(conversation: conversation)` reference remains in the file:

```bash
grep -c "VerifySecurityCodeView(conversation: conversation)" Features/Chats/Presentation/ConversationInfoView.swift
```

Expected: `1`.

- [ ] **Step 2: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ConversationInfoView.swift && \
git commit -m "$(cat <<'EOF'
fix(chats): collapse duplicate Verify Security / Encryption Keys rows

ConversationInfoView.securitySection had two NavigationLinks both
calling VerifySecurityCodeView(conversation:). Identical destinations,
two rows. Collapsed into a single "Encryption" row labeled
"Verify security code and view keys" with the lock.shield.fill icon.
Destination is unchanged — the existing screen already shows
fingerprint, QR, verify action, and encryption details on one
screen, matching the merged-row mental model.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 4.**

---

## Phase 5 — Inline Media & Links section in ConversationInfoView

Goal: replace the placeholder `mediaSection` with a real most-recent-6 grid that taps through to the existing Phase 2 `MediaGalleryView` from the bubble-viewers feature, and a "View All" button that navigates to the new `SharedContentView` (built in Phase 6).

### Task 12: Replace `mediaSection` with a real recent-media grid

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ConversationInfoView.swift`

- [ ] **Step 1: Add `@State` for the recent media + the gallery presentation**

At the top of `struct ConversationInfoView: View` find the `@State private var showWallpaper = false` line (around line 19). Add immediately below:

```swift
    @State private var recentMedia: [Message] = []
    @State private var totalMediaCount: Int = 0
    @State private var allChatMedia: [Message] = []
    @State private var galleryPresentation: ConversationInfoGalleryPresentation?
    @State private var showSharedContent = false
```

- [ ] **Step 2: Add a small Identifiable wrapper at file scope (top of file, after imports)**

```swift
private struct ConversationInfoGalleryPresentation: Identifiable {
    let id = UUID()
    let items: [Message]
    let initialIndex: Int
}
```

- [ ] **Step 3: Replace the body of `mediaSection`**

Find `private var mediaSection: some View {` (line 204). Replace the entire computed property body:

```swift
    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Media & Links")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Spacer()
                Button {
                    showSharedContent = true
                } label: {
                    Text("View All")
                        .font(SanchrTypography.messageBubbleText)
                        .fontWeight(.medium)
                        .foregroundColor(SanchrColors.primary)
                }
                .buttonStyle(.plain)
            }

            if recentMedia.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                        .foregroundColor(SanchrExportColors.textTertiary)
                    Text("No media shared yet")
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(SanchrExportColors.textSecondary)
                    Text("Photos, videos, and files shared in this conversation will appear here")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(Array(recentMedia.enumerated()), id: \.element.id) { index, message in
                        ConversationInfoMediaThumbnail(
                            message: message,
                            resolver: container.chatMediaResolver
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture {
                            galleryPresentation = ConversationInfoGalleryPresentation(
                                items: allChatMedia,
                                initialIndex: allChatMedia.firstIndex(where: { $0.id == message.id }) ?? 0
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }
```

- [ ] **Step 4: Add a `.task` to load recent media when the view appears**

Find the existing `.navigationDestination(isPresented: $showWallpaper)` block. Add **before** it (or alongside the other view-level modifiers on the outermost `ScrollView` / `VStack`):

```swift
        .task {
            await loadRecentMediaIfNeeded()
        }
        .navigationDestination(isPresented: $showSharedContent) {
            SharedContentView(conversation: conversation)
        }
        .fullScreenCover(item: $galleryPresentation) { presentation in
            // Reuse the bubble-viewers MediaGalleryView from Phase 2 of
            // the previous feature. The gallery already handles image
            // pinch-zoom, video playback, and swipe-to-dismiss.
            let galleryItems = presentation.items.compactMap { msg -> GalleryItem? in
                switch msg.content {
                case .image: return GalleryItem(id: msg.id, kind: .image, message: msg)
                case .video: return GalleryItem(id: msg.id, kind: .video, message: msg)
                default: return nil
                }
            }
            MediaGalleryView(
                presentation: MediaGalleryCoordinator.GalleryPresentation(
                    items: galleryItems,
                    initialIndex: presentation.initialIndex
                ),
                resolver: container.chatMediaResolver,
                onDismiss: { galleryPresentation = nil }
            )
        }
```

- [ ] **Step 5: Add the loader helper at the bottom of `ConversationInfoView`**

Just before the closing `}` of `struct ConversationInfoView: View`, add:

```swift
    private func loadRecentMediaIfNeeded() async {
        guard recentMedia.isEmpty else { return }
        let messages = (try? await container.localDatabase.fetchMessages(
            conversationId: conversation.id,
            before: nil,
            limit: 500
        )) ?? []
        let media = messages.filter { msg in
            switch msg.content {
            case .image, .video: return true
            default: return false
            }
        }
        let sorted = media.sorted { $0.timestamp < $1.timestamp }
        allChatMedia = sorted
        totalMediaCount = sorted.count
        recentMedia = Array(sorted.suffix(6).reversed())
    }
```

The `suffix(6).reversed()` produces the most recent 6 in newest-first order. `allChatMedia` keeps the chronological-asc order so the gallery `firstIndex(where:)` lookup matches the gallery seeding from the bubble-viewers feature.

- [ ] **Step 6: Add a small `ConversationInfoMediaThumbnail` view at file scope**

After the `ConversationInfoGalleryPresentation` struct from Step 2, add:

```swift
private struct ConversationInfoMediaThumbnail: View {
    let message: Message
    let resolver: ChatMediaResolving

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(SanchrExportColors.surfaceSoft)
            }
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        .task(id: message.id) {
            await loadThumbnail()
        }
    }

    private var isVideo: Bool {
        if case .video = message.content { return true }
        return false
    }

    private func loadThumbnail() async {
        guard let attachment = Self.attachment(for: message) else { return }
        do {
            let url = try await resolver.decryptedURL(
                forMessageId: message.id,
                attachment: attachment
            )
            if let img = UIImage(contentsOfFile: url.path) {
                await MainActor.run { self.image = img }
            }
        } catch {
            // Silent: leave the placeholder rectangle.
        }
    }

    private static func attachment(for message: Message) -> Message.MediaAttachment? {
        switch message.content {
        case .image(let a), .video(let a): return a
        default: return nil
        }
    }
}
```

- [ ] **Step 7: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

(`SharedContentView` is referenced from Step 4 but doesn't exist yet — Phase 6 builds it. To keep this phase compilable on its own, **add a temporary stub** in Step 8.)

- [ ] **Step 8: Add a temporary stub for `SharedContentView`**

Create `Features/Chats/Presentation/SharedContent/SharedContentView.swift` with a placeholder that Phase 6 will replace:

```swift
import SwiftUI
import SanchrShared

struct SharedContentView: View {
    let conversation: Conversation

    var body: some View {
        Text("Shared content — coming in Phase 6")
            .foregroundColor(.secondary)
            .navigationTitle("Shared")
    }
}
```

Regenerate the project so Xcode picks up the new file:

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && /opt/homebrew/bin/xcodegen generate
```

- [ ] **Step 9: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ConversationInfoView.swift \
        Features/Chats/Presentation/SharedContent/SharedContentView.swift \
        Sanchr.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
feat(chats): real Media & Links inline grid in ConversationInfoView

Replaces the placeholder mediaSection (hardcoded mediaCount = 0,
no-op View All) with a 3x2 grid of the most recent 6 image/video
messages from the chat. Tap → reuses the Phase 2 MediaGalleryView
from the bubble-viewers feature, seeded with all chat media in
chronological order. View All navigates to a new SharedContentView
(stub here, real impl in Phase 6).

Loader uses container.localDatabase.fetchMessages with a 500-message
recency window — bigger than 6 so the ordering survives gaps where
several text messages sit between media items, but bounded so the
section load doesn't block on enormous chats. Thumbnails are
ChatMediaResolving-backed so they reuse the existing decrypt
pipeline.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 5.**

---

## Phase 6 — `SharedContentView` (Media / Links / Docs tabs)

Goal: replace the Phase 5 stub with a real tabbed shared-content browser. Each tab paginates independently. Per-tab tap behavior reuses existing Phase 2 / Phase 6 viewers from the bubble-interactions feature.

### Task 13: `SharedContentViewModel` + tests

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/SharedContent/SharedContentViewModel.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/SharedContentViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/UnitTests/Features/Chats/SharedContentViewModelTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class SharedContentViewModelTests: XCTestCase {

    func test_loadInitial_partitionsMessagesIntoBuckets() async {
        let db = MockLocalDatabase()
        db.fetchMessagesResult = [
            Self.image(id: "i1", at: 100),
            Self.text(id: "t1", at: 200, body: "see https://example.com"),
            Self.document(id: "d1", at: 300, filename: "report.pdf"),
            Self.video(id: "v1", at: 400),
            Self.text(id: "t2", at: 500, body: "no link"),
            Self.text(id: "t3", at: 600, body: "https://news.example.org/story"),
        ]
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)

        XCTAssertEqual(vm.media.map(\.id), ["v1", "i1"])
        XCTAssertEqual(vm.docs.map(\.id), ["d1"])
        XCTAssertEqual(vm.links.map(\.id), ["t3", "t1"])
    }

    func test_loadInitial_emptyMessagesProducesEmptyBuckets() async {
        let db = MockLocalDatabase()
        db.fetchMessagesResult = []
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)

        XCTAssertTrue(vm.media.isEmpty)
        XCTAssertTrue(vm.docs.isEmpty)
        XCTAssertTrue(vm.links.isEmpty)
        XCTAssertFalse(vm.hasMore)
    }

    func test_loadMore_appendsAndUpdatesCursor() async {
        let db = MockLocalDatabase()
        db.fetchMessagesResult = [Self.image(id: "i1", at: 100)]
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)
        XCTAssertEqual(vm.media.map(\.id), ["i1"])

        // Next page returns one older media item.
        db.fetchMessagesResult = [Self.image(id: "i0", at: 50)]
        await vm.loadMore(conversationId: "conv", localDatabase: db)

        XCTAssertEqual(vm.media.map(\.id), ["i1", "i0"])
    }

    func test_linkExtractionPicksUpFirstURLOnly() async {
        let db = MockLocalDatabase()
        db.fetchMessagesResult = [
            Self.text(id: "t1", at: 100, body: "first https://a.example second https://b.example"),
        ]
        let vm = SharedContentViewModel()

        await vm.loadInitial(conversationId: "conv", localDatabase: db)

        XCTAssertEqual(vm.links.count, 1)
        XCTAssertEqual(vm.links.first?.url.absoluteString, "https://a.example")
    }

    // MARK: - Builders

    private static func image(id: String, at ts: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .image(Self.attachment("image/jpeg")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func video(id: String, at ts: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .video(Self.attachment("video/mp4")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func document(id: String, at ts: TimeInterval, filename: String) -> Message {
        var att = Self.attachment("application/pdf")
        att.filename = filename
        return Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .document(att),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func text(id: String, at ts: TimeInterval, body: String) -> Message {
        Message(
            id: id,
            conversationId: "conv",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            content: .text(body),
            status: .sent,
            isOutgoing: false
        )
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

- [ ] **Step 2: Confirm `MockLocalDatabase` has a settable `fetchMessagesResult`**

```bash
grep -n "fetchMessagesResult\|func fetchMessages" Tests/UnitTests/TestDoubles.swift | head
```

If `MockLocalDatabase.fetchMessages(...)` doesn't already return a settable variable, add:

```swift
    var fetchMessagesResult: [Message] = []

    func fetchMessages(
        conversationId: String,
        before: Date?,
        limit: Int
    ) async throws -> [Message] {
        fetchMessagesResult
    }
```

(If a `fetchMessages` already exists with a different signature/behavior, update it to read from `fetchMessagesResult` while preserving any other tests' expectations — read the existing mock body before patching.)

- [ ] **Step 3: Create `SharedContentViewModel.swift`**

```swift
import Foundation
import SanchrShared

/// Drives the SharedContentView's three tabs (Media / Links / Docs).
/// Loads paginated message batches from LocalDatabase and partitions
/// each batch into the three buckets in one pass so a single fetch
/// populates whatever tab the user lands on.
@Observable
@MainActor
final class SharedContentViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case media, links, docs
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .media: return "Media"
            case .links: return "Links"
            case .docs:  return "Docs"
            }
        }
    }

    struct LinkItem: Identifiable, Equatable, Hashable {
        let id: String              // messageId
        let url: URL
        let displayDomain: String
        let date: Date
    }

    var currentTab: Tab = .media
    var media: [Message] = []   // newest-first
    var links: [LinkItem] = []  // newest-first
    var docs: [Message] = []    // newest-first
    var isLoading: Bool = false
    var hasMore: Bool = true

    private static let pageSize = 100
    private var oldestLoadedTimestamp: Date?

    func loadInitial(
        conversationId: String,
        localDatabase: LocalDatabaseProtocol
    ) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        media.removeAll()
        links.removeAll()
        docs.removeAll()
        oldestLoadedTimestamp = nil
        hasMore = true
        await fetchPage(conversationId: conversationId, localDatabase: localDatabase)
    }

    func loadMore(
        conversationId: String,
        localDatabase: LocalDatabaseProtocol
    ) async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        await fetchPage(conversationId: conversationId, localDatabase: localDatabase)
    }

    private func fetchPage(
        conversationId: String,
        localDatabase: LocalDatabaseProtocol
    ) async {
        let batch: [Message]
        do {
            batch = try await localDatabase.fetchMessages(
                conversationId: conversationId,
                before: oldestLoadedTimestamp,
                limit: Self.pageSize
            )
        } catch {
            hasMore = false
            return
        }
        if batch.isEmpty {
            hasMore = false
            return
        }
        oldestLoadedTimestamp = batch.map(\.timestamp).min()
        if batch.count < Self.pageSize {
            hasMore = false
        }
        partition(batch)
    }

    /// Single-pass partitioning. Sorts the resulting buckets newest-first
    /// because the message batch from LocalDatabase isn't guaranteed
    /// chronological in either direction.
    private func partition(_ batch: [Message]) {
        var newMedia: [Message] = []
        var newDocs: [Message] = []
        var newLinks: [LinkItem] = []

        for message in batch {
            switch message.content {
            case .image, .video:
                newMedia.append(message)
            case .document:
                newDocs.append(message)
            case .text(let body):
                if let url = LinkPreviewService.firstURL(in: body) {
                    newLinks.append(LinkItem(
                        id: message.id,
                        url: url,
                        displayDomain: url.host ?? url.absoluteString,
                        date: message.timestamp
                    ))
                }
            default:
                break
            }
        }

        media.append(contentsOf: newMedia)
        docs.append(contentsOf: newDocs)
        links.append(contentsOf: newLinks)

        media.sort { $0.timestamp > $1.timestamp }
        docs.sort { $0.timestamp > $1.timestamp }
        links.sort { $0.date > $1.date }
    }
}
```

- [ ] **Step 4: Run the tests, confirm pass**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test \
  -only-testing:SanchrTests/SharedContentViewModelTests 2>&1 | tail -10
```

Expected: all 4 tests pass. (Sim-NIO caveat applies — fall back to main-target build verification if needed.)

- [ ] **Step 5: Build the main target**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/SharedContent/SharedContentViewModel.swift \
        Tests/UnitTests/Features/Chats/SharedContentViewModelTests.swift \
        Tests/UnitTests/TestDoubles.swift \
        Sanchr.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
feat(chats): SharedContentViewModel pagination + bucketization

Drives the new SharedContentView. Single-pass partitioning of each
fetched message batch into media / docs / links buckets, with
newest-first sort applied after each append. LinkPreviewService.firstURL
extracts the URL from text messages. Pagination uses the existing
fetchMessages(conversationId:before:limit:) cursor (oldest-loaded
timestamp). hasMore flips false when a fetch returns fewer than the
page size, so the load-more affordance hides at the end.

Tests cover: partition correctness, empty batch, append-on-load-more,
first-URL-only extraction.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: `SharedContentView` real implementation

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/SharedContent/SharedContentView.swift`

- [ ] **Step 1: Replace the Phase 5 stub with the real view**

Open the file and replace the entire body:

```swift
import SwiftUI
import SanchrShared

struct SharedContentView: View {
    let conversation: Conversation

    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SharedContentViewModel()
    @State private var galleryPresentation: SharedContentGalleryPresentation?
    @State private var documentURL: SharedContentDocURL?

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            contentBody
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Shared")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadInitial(
                conversationId: conversation.id,
                localDatabase: container.localDatabase
            )
        }
        .fullScreenCover(item: $galleryPresentation) { presentation in
            MediaGalleryView(
                presentation: MediaGalleryCoordinator.GalleryPresentation(
                    items: presentation.items,
                    initialIndex: presentation.initialIndex
                ),
                resolver: container.chatMediaResolver,
                onDismiss: { galleryPresentation = nil }
            )
        }
        .fullScreenCover(item: $documentURL) { wrapped in
            DocumentPreviewView(
                fileURL: wrapped.url,
                onDismiss: { documentURL = nil }
            )
        }
    }

    @ViewBuilder
    private var tabPicker: some View {
        Picker("Shared content tab", selection: $viewModel.currentTab) {
            ForEach(SharedContentViewModel.Tab.allCases) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch viewModel.currentTab {
        case .media: mediaTab
        case .links: linksTab
        case .docs:  docsTab
        }
    }

    @ViewBuilder
    private var mediaTab: some View {
        if viewModel.media.isEmpty && !viewModel.isLoading {
            emptyState(icon: "photo.on.rectangle.angled", text: "No media in this chat")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                    spacing: 2
                ) {
                    ForEach(Array(viewModel.media.enumerated()), id: \.element.id) { _, message in
                        SharedContentMediaCell(
                            message: message,
                            resolver: container.chatMediaResolver
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .onTapGesture {
                            openGallery(for: message)
                        }
                    }
                }
                .padding(.horizontal, 2)

                loadMoreFooter
            }
        }
    }

    @ViewBuilder
    private var linksTab: some View {
        if viewModel.links.isEmpty && !viewModel.isLoading {
            emptyState(icon: "link", text: "No links shared")
        } else {
            List {
                ForEach(viewModel.links) { link in
                    Button {
                        UIApplication.shared.open(link.url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.system(size: 18))
                                .frame(width: 28, height: 28)
                                .foregroundColor(SanchrColors.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.displayDomain)
                                    .font(SanchrTypography.messageBubbleText)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .lineLimit(1)
                                Text(link.url.absoluteString)
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(link.date.formatted(date: .abbreviated, time: .omitted))
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(SanchrExportColors.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if viewModel.hasMore {
                    loadMoreRow
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var docsTab: some View {
        if viewModel.docs.isEmpty && !viewModel.isLoading {
            emptyState(icon: "doc.fill", text: "No documents shared")
        } else {
            List {
                ForEach(viewModel.docs) { message in
                    if case .document(let attachment) = message.content {
                        Button {
                            Task { await openDocument(message: message, attachment: attachment) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: Self.iconName(for: attachment.mimeType))
                                    .font(.system(size: 22))
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(SanchrColors.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.filename ?? attachment.url.lastPathComponent)
                                        .font(SanchrTypography.messageBubbleText)
                                        .foregroundColor(SanchrExportColors.textPrimary)
                                        .lineLimit(1)
                                    Text(Self.formatBytes(attachment.sizeBytes))
                                        .font(SanchrTypography.captionSmall)
                                        .foregroundColor(SanchrExportColors.textSecondary)
                                }
                                Spacer()
                                Text(message.timestamp.formatted(date: .abbreviated, time: .omitted))
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if viewModel.hasMore {
                    loadMoreRow
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if viewModel.hasMore {
            Button {
                Task {
                    await viewModel.loadMore(
                        conversationId: conversation.id,
                        localDatabase: container.localDatabase
                    )
                }
            } label: {
                Text(viewModel.isLoading ? "Loading…" : "Load More")
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrColors.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .disabled(viewModel.isLoading)
        }
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        Button {
            Task {
                await viewModel.loadMore(
                    conversationId: conversation.id,
                    localDatabase: container.localDatabase
                )
            }
        } label: {
            HStack {
                Spacer()
                Text(viewModel.isLoading ? "Loading…" : "Load More")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrColors.primary)
                Spacer()
            }
        }
        .disabled(viewModel.isLoading)
    }

    @ViewBuilder
    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(SanchrExportColors.textTertiary)
            Text(text)
                .font(SanchrTypography.messageBubbleText)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Actions

    private func openGallery(for tappedMessage: Message) {
        let galleryItems = viewModel.media
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { msg -> GalleryItem? in
                switch msg.content {
                case .image: return GalleryItem(id: msg.id, kind: .image, message: msg)
                case .video: return GalleryItem(id: msg.id, kind: .video, message: msg)
                default: return nil
                }
            }
        let initialIndex = galleryItems.firstIndex(where: { $0.id == tappedMessage.id }) ?? 0
        galleryPresentation = SharedContentGalleryPresentation(
            items: galleryItems,
            initialIndex: initialIndex
        )
    }

    private func openDocument(message: Message, attachment: Message.MediaAttachment) async {
        do {
            let url = try await container.chatMediaResolver.decryptedURLWithDisplayName(
                forMessageId: message.id,
                attachment: attachment
            )
            documentURL = SharedContentDocURL(url: url)
        } catch {
            // Silent: could surface an alert here in a future iteration.
        }
    }

    // MARK: - Formatting helpers

    private static func iconName(for mime: String) -> String {
        if mime.contains("pdf") { return "doc.text.fill" }
        if mime.contains("word") || mime.contains("officedocument.wordprocessingml") { return "doc.fill" }
        if mime.contains("sheet") || mime.contains("excel") { return "tablecells.fill" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.stack.fill" }
        return "doc"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct SharedContentGalleryPresentation: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let initialIndex: Int
}

private struct SharedContentDocURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SharedContentMediaCell: View {
    let message: Message
    let resolver: ChatMediaResolving

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(SanchrExportColors.surfaceSoft)
            }
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        .clipped()
        .task(id: message.id) {
            await loadThumbnail()
        }
    }

    private var isVideo: Bool {
        if case .video = message.content { return true }
        return false
    }

    private func loadThumbnail() async {
        guard let attachment = Self.attachment(for: message) else { return }
        do {
            let url = try await resolver.decryptedURL(
                forMessageId: message.id,
                attachment: attachment
            )
            if let img = UIImage(contentsOfFile: url.path) {
                await MainActor.run { self.image = img }
            }
        } catch {
            // Silent: leave the placeholder rectangle.
        }
    }

    private static func attachment(for message: Message) -> Message.MediaAttachment? {
        switch message.content {
        case .image(let a), .video(let a): return a
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Build**

Run the standard build verification command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual sanity (no commit yet)**

Open Conversation Info on a chat with mixed content → tap "View All". The tabbed screen should appear. Switch tabs, verify each loads. Tap a media tile (gallery opens). Tap a doc (QuickLook opens with original filename). Tap a link (Safari opens).

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/SharedContent/SharedContentView.swift && \
git commit -m "$(cat <<'EOF'
feat(chats): SharedContentView with Media / Links / Docs tabs

Replaces the Phase 5 stub. Three tabs via Picker(.segmented),
each tab is a separate view body switched on viewModel.currentTab.

- Media: 3-col LazyVGrid of decrypted thumbnails via
  ChatMediaResolving. Tap → existing Phase 2 MediaGalleryView
  seeded with all loaded media in chronological order. Video
  thumbnails get a play badge.
- Links: List rows with globe icon, displayDomain, full URL,
  date. Tap → UIApplication.shared.open(url) (system browser).
- Docs: List rows with mime-type-aware SF Symbol, filename,
  byte-formatted size, date. Tap → ChatMediaResolving.decryptedURLWithDisplayName
  → DocumentPreviewView (Phase 6 of bubble-viewers feature)
  with the original filename preserved.

Per-tab "Load More" affordances paginate via the view model's
oldestLoadedTimestamp cursor. Empty states per tab. Bound to the
existing container.localDatabase + container.chatMediaResolver.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**End of Phase 6.**

---

## Phase 7 — Final verification + smoke matrix

Goal: confirm everything ships green and the user-visible behaviors all work end-to-end.

### Task 15: Build, full test suite, smoke matrix

**Files:** none — verification only.

- [ ] **Step 1: Run the standard build verification command**

Expected: `** BUILD SUCCEEDED **`. Any build failure = back to the offending phase.

- [ ] **Step 2: Run the full unit test suite**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests \
  -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. If the simulator NIO build is still broken (pre-existing across the bubble-viewers feature), confirm the new tests at minimum compile and accept that execution is blocked by the same infra issue. Document the deferred run in the commit message of any follow-up that fixes the sim NIO issue.

- [ ] **Step 3: Manual smoke matrix on a real device or arm64 sim**

| # | Action | Expected |
|---|---|---|
| 1 | Open Conversation Info on a chat with images | Inline 3×2 grid shows the 6 most recent media items |
| 2 | Tap a thumbnail | Phase 2 gallery opens at that item, swipe paginates across all chat media |
| 3 | Tap "View All" | `SharedContentView` opens on Media tab |
| 4 | Switch to Links tab | List of all links found in the chat with globe icon + domain + date |
| 5 | Tap a link | Opens in Safari |
| 6 | Switch to Docs tab | List of all docs with mime-type icon + filename + size |
| 7 | Tap a doc | QuickLook opens with the original filename |
| 8 | Scroll to bottom of any tab | "Load More" loads the next 100 messages worth |
| 9 | Open Conversation Info → Encryption row exists once | Single "Encryption" row, not two |
| 10 | Tap Encryption | Existing `VerifySecurityCodeView` opens unchanged |
| 11 | Open Settings → Appearance → toggle Dark Mode | Whole app flips dark/light, persists across launches |
| 12 | Settings → Appearance → pick a wallpaper | All chats render that wallpaper |
| 13 | Open a chat → Conversation Info → Wallpaper & Theme | Scope banner reads "Inheriting global appearance" |
| 14 | Pick a different wallpaper | Banner flips to "Applied to this chat only", chat detail shows the new wallpaper, other chats unchanged |
| 15 | Toggle Dark Mode in per-chat picker | Wallpaper auto-switches to a dark variant if it wasn't already; nav bar tints dark |
| 16 | Tap "Reset to Global" | Override clears, picker selection re-syncs to global, banner reverts |
| 17 | Force-quit and reopen | Per-chat override persists |
| 18 | Logout / delete account | Per-chat overrides wiped (the existing `purgeAllData()` cascades the new table automatically via the FK to `conversation.id`) |

- [ ] **Step 4: Commit any fixes**

If any rows fail, fix them in targeted commits:

```bash
git add <fixed files>
git commit -m "fix(chats): <specific fix>"
```

- [ ] **Step 5: Final milestone commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git commit --allow-empty -m "chore: conversation info rework feature complete"
```

---

## Out of scope (not in this plan)

- Server-side per-chat appearance sync. Deliberately deferred.
- Image-based wallpapers (custom photos). Registry is gradient-only.
- `MediaCellOverlay` extraction into a shared component. The plan duplicates the play-badge styling between `ConversationInfoMediaThumbnail`, `SharedContentMediaCell`, and the existing `AttachmentPickerRecentsStrip`. The spec listed an extraction as a "modified file" but it's strictly a refactor: defer until a third caller emerges or the duplication starts costing time. Removed from scope here.
- Search inside `SharedContentView`.
- Multi-select / batch share inside `SharedContentView`.
- Per-conversation accent color or font size overrides. Possible future extension on the `AppearanceOverride` struct.
- Touching any view that uses Liquid Glass APIs. Hard rule from the user's directive.
