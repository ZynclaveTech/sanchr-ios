# Conversation Info Rework — Design Spec

**Date:** 2026-04-08
**Status:** Approved for planning
**Scope:** iOS client only. New SQLCipher columns on the existing `conversations` table. No backend changes. No proto changes.

## 1. Problem

Three independent issues all live inside the Conversation Info screen ecosystem:

1. **Media & Links section is a placeholder.** `ConversationInfoView.mediaSection` hardcodes `mediaCount = 0`, ships an empty-state copy, and the "View All" button does nothing. The screen never queries the chat for shared media. Today there is also no way to browse all images, links, or documents shared in a conversation in any other surface.

2. **"Verify Security Code" and "Encryption Keys" rows both navigate to the same view.** `ConversationInfoView.securitySection` has two `NavigationLink`s, both calling `VerifySecurityCodeView(conversation:)` (lines 283 and 296). Identical destination, two rows, no functional difference. Pure duplication.

3. **Wallpaper & Theme is non-functional and unsynced.**
   - The private `WallpaperThemeView` inside `ConversationInfoView.swift` (lines 1142-1253) holds local-only `@State` (`darkMode = false`, `selectedWallpaper = 0`). Selecting a wallpaper does nothing visible. The Reset button is empty. The Dark Mode toggle does nothing.
   - The global `AppearanceView` (`Features/Settings/Presentation/AppearanceView.swift`) writes to `viewModel.chatWallpaper` and syncs to the backend via `SettingsViewModel`, but **nothing in the chat actually reads `chatWallpaper`** — so the global picker also does nothing visible.
   - The global `SanchrTheme` in `SanchrShared/DesignSystem/Theme.swift` is wired through `AppearanceView` and `@AppStorage("sanchr.themeMode")`, but `EnvironmentKey.defaultValue = SanchrTheme()` returns a new instance per environment read AND no view in the tree calls the existing `.sanchrThemed()` modifier — so toggling light/dark in Settings mutates a throwaway object that never feeds `.preferredColorScheme`.
   - Per-chat overrides have no storage or merge logic at all.

## 2. Goals

1. **Inline media preview** in `ConversationInfoView` shows the most recent 6 media items from the chat, tap-through to the existing Phase 2 `MediaGalleryView`.
2. **Tabbed `SharedContentView`** screen with Media / Links / Docs tabs, paginated, each with type-appropriate cells and per-cell tap behavior (gallery / Safari / QuickLook).
3. **Single Encryption row** in `ConversationInfoView.securitySection`, replacing the duplicated pair, navigating to the existing `VerifySecurityCodeView` unchanged.
4. **Wallpaper & Theme actually works** end-to-end:
   - Global picker in `AppearanceView` and per-chat picker in `WallpaperThemeView` read from one wallpaper registry.
   - `ChatDetailView` actually paints the wallpaper.
   - The dark/light mode toggle (global and per-chat) actually flips the rendered scheme.
   - Per-chat overrides cascade over global, never the reverse.
5. **No new metadata leaves the device.** Per-chat overrides are local-only; the existing global settings sync is preserved unchanged.
6. **Liquid Glass APIs the user has added are not modified.** Any view that already uses a liquid-glass background or material stays as-is — this work only edits the surfaces explicitly listed in §6.

## 3. Non-Goals

- Server-side per-chat appearance sync. Per-chat overrides do not propagate across devices. (Future work; out of scope.)
- New wallpaper assets / image-based wallpapers. The wallpaper registry contains gradient definitions only — same vocabulary as today's `AppearanceView` and `WallpaperThemeView`, just unified.
- Group-chat customization differences (group icon, name, members list editing).
- Reworking `VerifySecurityCodeView` itself. The screen content stays — only the row that navigates to it changes.
- Touching any view that already uses Liquid Glass. The work in §6 lists the affected files; nothing else is in scope.
- Pagination beyond 100-message batches in `SharedContentView`. If the chat is enormous, the user can keep loading more, but no infinite virtualization or windowing.

## 4. Architecture

### 4.1 Data model

**New SQLCipher columns** on the existing `conversations` table:

```sql
ALTER TABLE conversations ADD COLUMN wallpaper_id TEXT NULL;
ALTER TABLE conversations ADD COLUMN appearance_mode TEXT NULL;
```

- `wallpaper_id` is a string ID drawn from the unified `WallpaperPainter` registry (e.g. `"default"`, `"indigo_mist"`, `"midnight"`, `"deep_blue"`). Nullable: `null` means "inherit from global".
- `appearance_mode` is `"light" | "dark" | null`. Null means "inherit from global".

**Migration:** registered as the next entry in `SanchrShared/Persistence/DatabaseSchema.swift` via `migrator.registerMigration("v4_chat_appearance_overrides")` (existing migrations are `v1_initial`, `v2_delivery_ack_queue`, `v3_access_key_entries`). Existing rows get `NULL` defaults. No data loss. The schema uses GRDB's `DatabaseMigrator` — there are no separate `.sql` files in this project.

**New Swift types** in `SanchrShared/Models/ChatAppearance.swift`:

```swift
public struct ChatAppearance: Equatable, Sendable {
    public let wallpaperId: String              // resolved (never nil)
    public let appearanceMode: SanchrTheme.Mode // resolved
    public let isPerChatOverride: Bool          // true if any field came from override row
}

public struct AppearanceOverride: Equatable, Sendable {
    public let wallpaperId: String?
    public let appearanceMode: SanchrTheme.Mode?
}
```

**`LocalDatabaseProtocol` additions:**

```swift
func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride?
func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws
func clearAppearanceOverride(conversationId: String) async throws
```

`set` upserts the row; if both `override.wallpaperId == nil` and `override.appearanceMode == nil`, it falls through to `clear` so the row never holds an all-null override.

### 4.2 `ChatAppearanceService` resolver

**New file:** `Shared/Services/ChatAppearanceService.swift`. Single source of truth for the global ↔ per-chat merge.

```swift
@Observable
@MainActor
public final class ChatAppearanceService {
    public var globalWallpaperId: String
    public var globalMode: SanchrTheme.Mode
    private var overrides: [String: AppearanceOverride] = [:]

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

    /// Cache-warm called from ChatDetailView.task. Idempotent.
    public func loadOverride(conversationId: String) async {
        guard overrides[conversationId] == nil else { return }
        if let row = try? await localDatabase.fetchAppearanceOverride(conversationId: conversationId) {
            overrides[conversationId] = row
        }
    }

    /// Per-chat write. nil + nil clears the row.
    public func setOverride(
        conversationId: String,
        wallpaperId: String?,
        appearanceMode: SanchrTheme.Mode?
    ) async {
        let override = AppearanceOverride(
            wallpaperId: wallpaperId,
            appearanceMode: appearanceMode
        )
        if wallpaperId == nil && appearanceMode == nil {
            try? await localDatabase.clearAppearanceOverride(conversationId: conversationId)
            overrides.removeValue(forKey: conversationId)
        } else {
            try? await localDatabase.setAppearanceOverride(override, for: conversationId)
            overrides[conversationId] = override
        }
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

**Lifetime:** `lazy var chatAppearance` on `DependencyContainer`, constructed with the shared `localDatabase`, `sanchrTheme` instance (see §4.3), and the `SettingsViewModel`. Single instance for the app's lifetime.

**Cache-warming:** `ChatDetailView.task` calls `loadOverride(conversationId:)` before first paint. Without warming, the first frame would render with global state and a millisecond later flicker to the override.

**`@Observable`:** any view that reads `effectiveAppearance(for:)` redraws when the override cache or global slot mutates. This is the propagation path for both pickers — they write through the service, the chat detail view reacts.

### 4.3 Global plumbing fixes (prerequisite for everything else)

**Bug 1: shared `SanchrTheme` instance.** `EnvironmentKey.defaultValue = SanchrTheme()` returns a fresh instance per environment read. Different views see different `SanchrTheme` objects. Mutations don't propagate.

**Fix:** at the app root in `App/SanchrApp.swift`, instantiate exactly one `@State private var sanchrTheme = SanchrTheme()`, inject into the environment, and rehydrate from `@AppStorage` once on startup:

```swift
@AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.light.rawValue
@State private var sanchrTheme = SanchrTheme()

var body: some Scene {
    WindowGroup {
        ContentView()
            .environment(\.sanchrTheme, sanchrTheme)
            .sanchrThemed()
            .task {
                if let saved = SanchrTheme.Mode(rawValue: storedThemeMode) {
                    sanchrTheme.mode = saved
                }
            }
    }
}
```

**Bug 2: `.sanchrThemed()` is never called.** The modifier already exists in `SanchrShared/DesignSystem/Theme.swift` and applies `.preferredColorScheme(theme.mode.colorScheme)`, but no view in the tree calls it. The fix above adds `.sanchrThemed()` at the root.

**Bug 3: chat doesn't paint the wallpaper.** `SettingsViewModel.chatWallpaper` is set + synced today but no chat-side view consumes it.

**Fix:** new `WallpaperPainter` registry + `chatBackground(wallpaperId:)` modifier in `SanchrShared/DesignSystem/`:

```swift
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

    public static func wallpaper(for id: String) -> Wallpaper {
        allWallpapers.first(where: { $0.id == id }) ?? allWallpapers[0]
    }

    public static func background(for id: String) -> some View {
        let wp = wallpaper(for: id)
        return LinearGradient(
            colors: wp.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

public struct ChatBackgroundModifier: ViewModifier {
    let wallpaperId: String
    public func body(content: Content) -> some View {
        content.background(WallpaperPainter.background(for: wallpaperId).ignoresSafeArea())
    }
}

public extension View {
    func chatBackground(wallpaperId: String) -> some View {
        modifier(ChatBackgroundModifier(wallpaperId: wallpaperId))
    }
}
```

**`ChatDetailView` consumption:** read the resolved appearance once at the top of `body`, apply both modifiers:

```swift
var body: some View {
    let appearance = container.chatAppearance.effectiveAppearance(for: conversation.id)
    VStack(spacing: 0) { ... }
        .chatBackground(wallpaperId: appearance.wallpaperId)
        .preferredColorScheme(appearance.appearanceMode.colorScheme)
        .task {
            await container.chatAppearance.loadOverride(conversationId: conversation.id)
        }
}
```

Both `AppearanceView` (the global picker) and `WallpaperThemeView` (the per-chat picker) get rewritten to read from `WallpaperPainter.allWallpapers` instead of their hand-rolled arrays.

### 4.4 Conversation Info screen rewrites

**Section 4a — Inline Media & Links section.**

Replace `mediaSection` in `ConversationInfoView.swift` (lines 202-271). Loads the most recent 6 image/video messages from the chat, renders a 3×2 `LazyVGrid` of aspect-fill thumbnails. Tap → opens existing Phase 2 `MediaGalleryView` seeded with the *full* media list from the chat (not just the visible 6) so swipe paging works across all media. The "View All" button navigates to the new `SharedContentView` (4b).

The empty state copy is preserved and gated on `mediaCount == 0`.

The data feed: a small computed property `recentMediaPreview` on a new `ConversationInfoViewModel` (or inline on the existing struct via `@State` populated from `.task`):

```swift
@State private var recentMedia: [Message] = []
@State private var totalMediaCount: Int = 0

private func loadRecentMedia() async {
    let allMessages = try? await container.localDatabase.fetchMessages(
        conversationId: conversation.id,
        before: nil,
        limit: 500   // best-effort recent window
    )
    let media = (allMessages ?? []).filter {
        switch $0.content {
        case .image, .video: return true
        default: return false
        }
    }
    recentMedia = Array(media.prefix(6))
    totalMediaCount = media.count
}
```

`fetchMessages(conversationId:before:limit:)` already exists on `LocalDatabaseProtocol`.

**Section 4b — `SharedContentView` (new file).**

`Features/Chats/Presentation/SharedContent/SharedContentView.swift` plus `SharedContentViewModel.swift`. Three tabs via SwiftUI `Picker(.segmented)` over a `Tab` enum, with the body switching on the selection:

```swift
enum SharedContentTab: String, CaseIterable, Identifiable {
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
```

**`SharedContentViewModel`:**

```swift
@Observable
@MainActor
final class SharedContentViewModel {
    var media: [Message] = []
    var links: [LinkItem] = []
    var docs: [Message] = []
    var currentTab: SharedContentTab = .media
    var isLoading = false
    var hasMore = true
    private var oldestLoadedTimestamp: Date?

    struct LinkItem: Identifiable, Equatable {
        let id: String              // messageId
        let url: URL
        let displayDomain: String
        let title: String?          // best-effort from existing link preview cache
        let date: Date
    }

    func loadInitial(conversationId: String, localDatabase: LocalDatabaseProtocol) async { ... }
    func loadMore(conversationId: String, localDatabase: LocalDatabaseProtocol) async { ... }
}
```

`loadInitial` fetches the most recent 100 messages and partitions them into the three buckets in one pass. `loadMore` uses `oldestLoadedTimestamp` as the `before:` cursor and fetches the next 100, appending to whichever bucket each message belongs to. The view shows a load-more affordance at the bottom of each tab when `hasMore == true`.

**Cell layouts:**

- **Media tab:** `LazyVGrid` (3 columns, 2pt spacing). Cell is an aspect-fill thumbnail (loaded via the existing `MediaDownloadManager` for the inline thumbnail variant — not the full file). For video items, the cell overlays a play badge and a small mm:ss duration label in the bottom-right (reusing the styling we already added to `AttachmentPickerRecentsStrip` — extract into a shared `MediaCellOverlay` view in `SanchrShared/DesignSystem/` so both surfaces stay in sync). Tap → presents the existing Phase 2 gallery via the same `MediaGalleryCoordinator` already in `ChatDetailView`.

- **Links tab:** `List`-style row. Leading: 24pt favicon (use the existing `LinkPreviewService` cache if available, else SF Symbol `globe`). Title: `LinkItem.title ?? URL.host`. Subtitle: `displayDomain`. Trailing: relative date. Tap → `UIApplication.shared.open(url)` (system default browser/Safari).

- **Docs tab:** `List`-style row. Leading: 28pt SF Symbol picked from MIME type (`doc.text.fill` for PDF, `doc.fill` for Word, `tablecells.fill` for spreadsheet, `doc` generic). Title: `attachment.filename ?? URL.lastPathComponent`. Subtitle: `ByteCountFormatter` size + relative date. Tap → calls the existing Phase 6 `DocumentPreviewCoordinator.open(messageId:)` from `ChatDetailView`'s container — but `SharedContentView` lives below `ConversationInfoView`, not under `ChatDetailView`, so it constructs its own short-lived `DocumentPreviewCoordinator` keyed to its own message lookup.

**Link extraction:** reuses `LinkPreviewService.firstURL(in:)` from `ChatDetailView.swift:1247`. Extract this helper into a new file `SanchrShared/Networking/LinkExtraction.swift` so `SharedContentViewModel` can call it without importing `ChatDetailView`. Just a move, no behavior change.

**Why a separate file:** `ConversationInfoView.swift` is already 1,853 lines. The tabbed screen + its view model + cell views inline would push it past 2,500. Per the project's "files that change together live together" guidance and the CLAUDE.md "files focused on one responsibility" rule, the shared content browsing belongs in its own folder.

**Section 4c — Encryption row collapse.**

Edit `ConversationInfoView.securitySection` (lines 275-315). Delete the second `NavigationLink` block (lines 296-307). Update the surviving row's `settingsRow(...)` arguments:

```swift
settingsRow(
    icon: "lock.shield.fill",
    iconBg: SanchrColors.primary.opacity(0.1),
    iconColor: SanchrColors.primary,
    title: "Encryption",
    subtitle: "Verify security code and view keys"
)
```

Destination is unchanged: `VerifySecurityCodeView(conversation: conversation)` already shows the safety number, the QR code, the verify action, and the encryption details on one screen.

**Section 4d — `WallpaperThemeView` rewrite.**

Replace the body of the existing private `WallpaperThemeView` struct in `ConversationInfoView.swift` (lines 1142-1253). Same nav destination, new internals.

`init` signature changes from `init()` to `init(conversationId: String)`. The single call site at the `.navigationDestination(isPresented: $showWallpaper)` block (line 74) updates to pass `conversation.id`.

```swift
private struct WallpaperThemeView: View {
    let conversationId: String
    @Environment(DependencyContainer.self) private var container
    @State private var selectedWallpaperId: String = "default"
    @State private var darkMode: Bool = false
    @State private var hasOverride: Bool = false
    @State private var isLoading = true

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
    private var darkModeToggleRow: some View { ... }

    @ViewBuilder
    private var wallpaperGrid: some View {
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
                    .onTapGesture {
                        selectedWallpaperId = wp.id
                        Task { await applyOverride() }
                    }
            }
        }
    }

    @ViewBuilder
    private var resetToGlobalButton: some View { ... }

    private func applyOverride() async {
        let mode: SanchrTheme.Mode = darkMode ? .dark : .light
        await container.chatAppearance.setOverride(
            conversationId: conversationId,
            wallpaperId: selectedWallpaperId,
            appearanceMode: mode
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
}
```

**Dark Mode toggle behavior (per Q4):** when `darkMode` flips ON, if the currently-selected wallpaper has `isDark == false`, auto-select the first dark wallpaper from `WallpaperPainter.allWallpapers.filter(\.isDark)`. When OFF, mirror: if the current wallpaper has `isDark == true`, auto-select the first light one. This makes the toggle semantically meaningful — picking a light wallpaper while in dark mode would otherwise be incoherent. The user can still pick a different wallpaper of either kind after the toggle.

**`AppearanceView` parallel update:** the global wallpaper grid in `Features/Settings/Presentation/AppearanceView.swift` swaps from `wallpaperOptions` to `WallpaperPainter.allWallpapers` and writes through `container.chatAppearance.setGlobal(...)`. Theme card writes go through the same service. The existing backend sync via `SettingsViewModel` is preserved because `setGlobal` mirrors to `settingsViewModel.chatWallpaper` and triggers the same sync path.

## 5. Error handling

- **`fetchAppearanceOverride` throws / returns nil:** treat as "no override" and fall back to global. No alert. The picker shows global state and `hasOverride = false`.
- **`setAppearanceOverride` throws:** swallow the error in the service (it's a `try?`) and log. The in-memory cache still updates, so the UI reflects the user's intent immediately, and the persistence retries on next mutation. Prevents a transient SQLCipher hiccup from stranding the picker.
- **Wallpaper id missing from registry:** `WallpaperPainter.wallpaper(for:)` returns the `default` wallpaper as a graceful fallback. Never crashes.
- **`SharedContentViewModel.loadInitial` returns empty:** each tab shows a per-type empty state ("No media in this chat", "No links shared", "No documents shared").
- **Link extraction failure:** the message is silently dropped from the Links tab. Already the contract of `LinkPreviewService.firstURL`.
- **Document tap when resolver is unavailable:** the existing `DocumentPreviewCoordinator` already handles missing/corrupt files via the alert + `UIDocumentInteractionController` fallback. No new error path.
- **`ChatBackgroundModifier` applied with an unknown wallpaper id:** falls back to default. No alert.

## 6. Files touched

### New files

| Path | Responsibility |
|---|---|
| `SanchrShared/Models/ChatAppearance.swift` | `ChatAppearance` + `AppearanceOverride` value types |
| `SanchrShared/DesignSystem/WallpaperPainter.swift` | Wallpaper registry + `chatBackground(wallpaperId:)` modifier |
| `SanchrShared/DesignSystem/MediaCellOverlay.swift` | Reusable video play-badge + duration overlay (shared between recents strip and SharedContent media tab) |
| `SanchrShared/Networking/LinkExtraction.swift` | Move of `LinkPreviewService.firstURL(in:)` so non-`ChatDetailView` consumers can use it |
| (no new file) | New `migrator.registerMigration("v4_chat_appearance_overrides")` block added to `SanchrShared/Persistence/DatabaseSchema.swift` — see Modified files |
| `Shared/Services/ChatAppearanceService.swift` | Resolver + global ↔ per-chat merge |
| `Features/Chats/Presentation/SharedContent/SharedContentView.swift` | Tabbed Media / Links / Docs screen |
| `Features/Chats/Presentation/SharedContent/SharedContentViewModel.swift` | Pagination + bucketization |
| `Tests/UnitTests/Features/Chats/ChatAppearanceServiceTests.swift` | Resolver merge + cache + overrides |
| `Tests/UnitTests/Features/Chats/SharedContentViewModelTests.swift` | Bucketization, link extraction, pagination cursor |

### Modified files

| Path | Change |
|---|---|
| `App/SanchrApp.swift` | Single `@State` `SanchrTheme` instance, `.environment(\.sanchrTheme,)`, `.sanchrThemed()`, AppStorage rehydration |
| `App/DependencyContainer.swift` | Expose `chatAppearance: ChatAppearanceService` |
| `Features/Chats/Presentation/ConversationInfoView.swift` | Rewrite `mediaSection`; collapse `securitySection` to one row; rewrite private `WallpaperThemeView`; pass `conversation.id` to its destination |
| `Features/Chats/Presentation/ChatDetailView.swift` | Apply `chatBackground` + `preferredColorScheme` from resolved appearance; cache-warm in `.task`; use the new shared `LinkExtraction` helper |
| `Features/Settings/Presentation/AppearanceView.swift` | Wallpaper grid + theme cards write through `chatAppearance.setGlobal(...)`; read from `WallpaperPainter.allWallpapers` |
| `Features/Chats/Presentation/AttachmentPicker/AttachmentPickerRecentsStrip.swift` | Replace inline play badge / duration label with the shared `MediaCellOverlay` |
| `SanchrShared/Persistence/DatabaseSchema.swift` | Register `v4_chat_appearance_overrides` migration that adds `wallpaper_id` and `appearance_mode` columns to the `conversations` table |
| `SanchrShared/Persistence/LocalDatabase.swift` | New `fetchAppearanceOverride` / `setAppearanceOverride` / `clearAppearanceOverride` methods + protocol entries |
| `Tests/UnitTests/TestDoubles.swift` | Mock `LocalDatabase` conformance for the three new methods |

### Files explicitly NOT touched

- `VerifySecurityCodeView` and any of its sub-views.
- Any view that already uses Liquid Glass APIs added by the user.
- Any backend / proto files.

## 7. Testing

**Unit tests** (no UIKit required):

- **`ChatAppearanceServiceTests`**:
  - `effectiveAppearance` returns global when no override.
  - `effectiveAppearance` returns override.wallpaperId, override.appearanceMode when both present.
  - `effectiveAppearance` mixes (override wallpaper, global mode) when only wallpaperId is set.
  - `setOverride(wallpaperId: nil, appearanceMode: nil)` calls `clearAppearanceOverride` and removes from cache.
  - `setGlobal(wallpaperId:)` mirrors to `SettingsViewModel.chatWallpaper`.
  - `setGlobal(appearanceMode:)` mirrors to `SanchrTheme.mode`.
  - `loadOverride` is idempotent (second call doesn't re-hit the DB).

- **`SharedContentViewModelTests`**:
  - `loadInitial` partitions a mixed message list into media / links / docs buckets in one pass.
  - Link extraction picks up the first URL via `LinkExtraction.firstURL`.
  - `loadMore` uses the oldest loaded timestamp as the cursor and appends to existing buckets.
  - Empty input → empty buckets, no pagination loop.

- **Existing `ConversationInfoView`** structure tests get a one-line update to assert the security row count is exactly 1, not 2.

**Manual smoke matrix** for Phase 7 of the implementation plan:

| # | Action | Expected |
|---|---|---|
| 1 | Open Conversation Info on a chat with images | Inline grid shows the most recent 6 media items |
| 2 | Tap a thumbnail | Phase 2 gallery opens at that item, swipe across all chat media works |
| 3 | Tap "View All" | `SharedContentView` opens on Media tab |
| 4 | Switch to Links tab | List of all links found in the chat with favicon + domain + date |
| 5 | Tap a link | Opens in Safari |
| 6 | Switch to Docs tab | List of all docs with mime-type icon + filename + size |
| 7 | Tap a doc | QuickLook opens with the original filename (Phase 6 behavior) |
| 8 | Scroll to bottom of any tab | "Load more" loads the next 100 messages worth |
| 9 | Open Conversation Info → Encryption row exists once | Single "Encryption" row, not two |
| 10 | Tap Encryption | Existing `VerifySecurityCodeView` opens unchanged |
| 11 | Open global Settings → Appearance → toggle Dark Mode | Whole app flips dark/light, persists across launches |
| 12 | Settings → Appearance → pick a wallpaper | All chats render that wallpaper |
| 13 | Open a chat → Conversation Info → Wallpaper & Theme | Scope banner reads "Inheriting global appearance" |
| 14 | Pick a different wallpaper | Banner flips to "Applied to this chat only", chat detail shows the new wallpaper, other chats unchanged |
| 15 | Toggle Dark Mode in per-chat picker | Wallpaper auto-switches to a dark variant if it wasn't already; nav bar tints dark |
| 16 | Tap "Reset to Global" | Override clears, picker selection re-syncs to global, banner reverts |
| 17 | Force-quit and reopen | Per-chat override persists |
| 18 | Logout / delete account | Per-chat overrides wiped (the existing `purgeAllData()` cascades the new columns automatically) |

## 8. Rollout

Single phase. Per-chat appearance is gated on the new SQLCipher columns; the migration is mandatory and runs on next launch. Global theme + wallpaper fixes are pure code changes — they take effect on first launch of the new build for every existing user, no migration needed for that part.

No feature flags. The Conversation Info screen is already shipped; this is a fix-and-extend, not a new surface.

## 9. Out of scope / future

- Per-chat group muting differences (already exists, untouched).
- Group avatar editing.
- Wallpaper *image* support (custom uploaded backgrounds, photo wallpaper). Out of scope; the registry is gradient-only.
- Per-conversation accent color or font size overrides. Possible future extension on the same `AppearanceOverride` struct.
- Cross-device sync of per-chat overrides. Would require a new proto + backend round-trip; deliberately deferred per Q3.
- Multi-link extraction per message. `LinkExtraction.firstURL` matches today's behavior.
- Search inside `SharedContentView`.
- Selecting multiple items in `SharedContentView` for batch share / save.

## 10. Open questions

None outstanding. All resolved during brainstorming:

- Q1 — Media section layout = inline preview + tabbed full screen
- Q2 — Encryption rows = single row, single destination
- Q3 — Per-chat override storage = local-only SQLCipher columns
- Q4 — Per-chat dark mode toggle = forces a dark wallpaper for this chat (with auto-switch when toggling)
