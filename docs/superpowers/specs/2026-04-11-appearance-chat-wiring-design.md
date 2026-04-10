# Appearance → Chat Wiring Design

**Date:** 2026-04-11
**Status:** Approved

## Problem

`AppearanceView` lets users set font size and chat bubble style. Both settings are saved (font size to the backend, bubble style to `@AppStorage`) but neither has any visible effect in the chat. `MessageBubble` hardcodes its font and corner radius, so every conversation looks identical regardless of the user's preference.

Additionally, the "More" wallpaper tile in `AppearanceView` is a static `RoundedRectangle` with no tap action — a non-button that looks tappable.

Theme mode and wallpaper are **not** broken — they already route through `ChatAppearanceService` correctly.

## Goals

1. Font size preference ("small" / "medium" / "large") visually changes message text in chat.
2. Bubble style preference ("modern" / "classic" / "compact") visually changes bubble corner radius in chat.
3. Changes take effect immediately (no restart required).
4. "More" wallpaper tile is removed.

## Non-Goals

- Syncing font size or bubble style to the backend (intentionally device-local).
- Per-conversation font size or bubble style overrides.
- Adding a custom photo wallpaper picker ("More" replacement is out of scope).
- Changing any font outside `MessageBubble` (chat list cells, headers, etc.).

## Architecture

Two files change. No new types, no protocol changes, no infrastructure changes.

```
AppearanceView (settings)
  slider onChange  → viewModel.fontSize = "large"
                   → @AppStorage("sanchr.fontSize") = "large"   ← NEW mirror
                   → debouncedSync() → backend (unchanged)
  .task {}         → loads viewModel.fontSize from backend
                   → @AppStorage("sanchr.fontSize") = viewModel.fontSize  ← NEW mirror

MessageBubble (inside ChatDetailView)
  @AppStorage("sanchr.fontSize")        → bubbleFont          ← NEW
  @AppStorage("sanchr.chatBubbleStyle") → bubbleCornerRadius  ← NEW (key existed, never read here)
```

`SanchrTypography`, `SanchrSpacing`, `ChatAppearanceService`, and the backend proto are untouched.

## Component Specification

### `AppearanceView.swift`

**Add property:**
```swift
@AppStorage("sanchr.fontSize") private var storedFontSize = "medium"
```

**In `.task {}` — after `fontStep = sliderValue(for: viewModel.fontSize)` line:**
```swift
storedFontSize = viewModel.fontSize
```

**In `.onChange(of: fontStep)` — after `viewModel.fontSize = newSize` line:**
```swift
storedFontSize = newSize
```

**Delete** the entire trailing `RoundedRectangle` block in `wallpaperSection` (the "More" tile with the `+` icon and "More" label). It is a static shape with no action.

### `ChatDetailView.swift` → `MessageBubble`

**Add two `@AppStorage` properties inside the `MessageBubble` struct:**
```swift
@AppStorage("sanchr.fontSize") private var fontSize = "medium"
@AppStorage("sanchr.chatBubbleStyle") private var bubbleStyle = "modern"
```

**Add two computed properties inside `MessageBubble`:**
```swift
private var bubbleFont: Font {
    switch fontSize {
    case "small": return SanchrTypography.caption
    case "large": return SanchrTypography.bodyLarge
    default:      return SanchrTypography.body
    }
}

private var bubbleCornerRadius: CGFloat {
    switch bubbleStyle {
    case "classic": return 999
    case "compact": return 10
    default:        return 20
    }
}
```

**Replace every usage of the hardcoded font inside `MessageBubble`:**
- `SanchrTypography.messageBubbleText` → `bubbleFont`

**Replace every usage of the hardcoded radius inside `MessageBubble`:**
- `SanchrSpacing.bubbleMainRadius` → `bubbleCornerRadius`

The tail radius (`SanchrSpacing.bubbleTailRadius`, 4pt) stays hardcoded — it is a fixed detail of the bubble tail geometry that does not vary by style.

## Data Flow

```
Cold start:
  .task {} in AppearanceView
    → loadSettings() → backend returns fontSize = "large"
    → viewModel.fontSize = "large"
    → storedFontSize = "large"            ← writes @AppStorage
  MessageBubble renders
    → reads @AppStorage("sanchr.fontSize") = "large"
    → bubbleFont = SanchrTypography.bodyLarge ✓

Live change:
  User drags font slider to "Large"
    → onChange fires → storedFontSize = "large"
    → SwiftUI sees @AppStorage change
    → MessageBubble re-renders with bodyLarge ✓
    → debouncedSync() fires 500ms later → backend updated ✓
```

## Error Handling

- If `@AppStorage("sanchr.fontSize")` has no value yet (first launch before `.task` runs), it defaults to `"medium"` — correct fallback.
- If `@AppStorage("sanchr.chatBubbleStyle")` has no value yet, it defaults to `"modern"` — correct fallback.
- Backend sync failures do not affect local rendering (debounced sync is fire-and-observe, not blocking).

## Testing

No unit-testable logic is introduced (two switch statements mapping string constants to existing constants). Verification is by:

1. Build succeeds.
2. In the simulator, change font size to "Large" in Appearance settings → open a conversation → message text is visibly larger.
3. Change bubble style to "Rounded" → message bubbles are pill-shaped.
4. Change bubble style to "Sharp" → message bubbles have tight corners.
5. Kill and relaunch the app → preferences are persisted.
6. "More" wallpaper tile is absent from the grid.

## Files Changed

| File | Change |
|------|--------|
| `Features/Settings/Presentation/AppearanceView.swift` | Add `storedFontSize` @AppStorage; write it in `.task` and `.onChange`; delete "More" tile |
| `Features/Chats/Presentation/ChatDetailView.swift` | Add `@AppStorage` reads + `bubbleFont` + `bubbleCornerRadius` to `MessageBubble`; replace hardcoded font and radius |
