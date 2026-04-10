# Appearance → Chat Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make font size and bubble style preferences set in AppearanceView visually apply to `MessageBubble` in ChatDetailView, and remove the non-functional "More" wallpaper tile.

**Architecture:** Add `@AppStorage("sanchr.fontSize")` as a local mirror in AppearanceView (written on load and on every change). MessageBubble reads both `@AppStorage` keys and computes `bubbleFont` / `bubbleCornerRadius` from them. SwiftUI re-renders bubbles reactively on preference change. Two files change; no new types.

**Tech Stack:** SwiftUI, `@AppStorage`, `SanchrTypography`, `SanchrSpacing`, Xcode scheme `Sanchr`

---

## File Map

| File | Role |
|------|------|
| `Sanchr-IOS/Features/Settings/Presentation/AppearanceView.swift` | Add `storedFontSize` @AppStorage; mirror `viewModel.fontSize` to it; delete "More" tile |
| `Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift` | Add @AppStorage reads + `bubbleFont` + `bubbleCornerRadius` to `MessageBubble`; replace hardcoded values |

---

### Task 1: Wire Font Size to @AppStorage in AppearanceView + Remove "More" Tile

**Files:**
- Modify: `Sanchr-IOS/Features/Settings/Presentation/AppearanceView.swift`

- [ ] **Step 1: Re-read the file**

```bash
wc -l /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/AppearanceView.swift
```

Expected: ~355 lines.

- [ ] **Step 2: Add `storedFontSize` @AppStorage property**

Add this line immediately after the existing `@AppStorage("sanchr.themeMode")` declaration (currently line 13):

Old:
```swift
    @AppStorage("sanchr.chatBubbleStyle") private var chatBubbleStyle = "modern"
    @AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.light.rawValue
```

New:
```swift
    @AppStorage("sanchr.chatBubbleStyle") private var chatBubbleStyle = "modern"
    @AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.light.rawValue
    @AppStorage("sanchr.fontSize") private var storedFontSize = "medium"
```

- [ ] **Step 3: Mirror fontSize to @AppStorage on backend load**

In the `.task {}` block, find the line:
```swift
            fontStep = sliderValue(for: viewModel.fontSize)
```

Add one line immediately after it:
```swift
            fontStep = sliderValue(for: viewModel.fontSize)
            storedFontSize = viewModel.fontSize
```

- [ ] **Step 4: Mirror fontSize to @AppStorage on slider change**

In `.onChange(of: fontStep)`, find:
```swift
                        let newSize = fontSize(for: newValue)
                        viewModel.fontSize = newSize
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
```

Add `storedFontSize = newSize` after the `viewModel.fontSize` assignment:
```swift
                        let newSize = fontSize(for: newValue)
                        viewModel.fontSize = newSize
                        storedFontSize = newSize
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
```

- [ ] **Step 5: Delete the "More" wallpaper tile**

In `wallpaperSection`, inside the `LazyVGrid`, find and delete the entire trailing `RoundedRectangle` block — from the blank line after the `ForEach` closing brace through the second `.overlay {}` closer. The block to delete is:

```swift
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SanchrExportColors.surface)
                    .frame(height: 108)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(SanchrExportColors.textTertiary)
                            Text("More")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(hex: 0xE5E7EB), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    }
```

- [ ] **Step 6: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Verify @AppStorage is written on load**

```bash
grep -n "storedFontSize" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/AppearanceView.swift
```

Expected: 3 hits — the property declaration, the `.task {}` assignment, and the `.onChange` assignment.

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Sanchr-IOS/Features/Settings/Presentation/AppearanceView.swift && \
git commit -m "$(cat <<'EOF'
feat(appearance): mirror fontSize to @AppStorage and remove More tile

AppearanceView now writes sanchr.fontSize to @AppStorage on backend
load and on every slider change, making the preference readable by
MessageBubble. The non-functional More wallpaper tile is removed.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add @AppStorage Reads and Computed Properties to MessageBubble

**Files:**
- Modify: `Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift`

> **Context:** `MessageBubble` is a private struct inside `ChatDetailView.swift` starting at line 1377. It has no @AppStorage properties today. The `bubbleShape` computed property (line 1696) is where the radius will be used.

- [ ] **Step 1: Re-read MessageBubble's opening block**

```bash
sed -n '1377,1395p' \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift
```

Confirm the block ends with the `static let fileSizeFormatter` initialiser.

- [ ] **Step 2: Add @AppStorage properties and computed properties after the `fileSizeFormatter` block**

Find this exact block:
```swift
    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
```

Replace with:
```swift
    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @AppStorage("sanchr.fontSize") private var fontSize = "medium"
    @AppStorage("sanchr.chatBubbleStyle") private var bubbleStyle = "modern"

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

- [ ] **Step 3: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(chat): add bubbleFont and bubbleCornerRadius computed props to MessageBubble

Reads sanchr.fontSize and sanchr.chatBubbleStyle from @AppStorage.
Properties are defined but not yet used — next task wires them in.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Replace Hardcoded Font and Radius Inside MessageBubble

**Files:**
- Modify: `Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift`

> **Critical:** `SanchrTypography.messageBubbleText` appears at **six** locations in this file — lines 667, 728, 1053, 1509, 1620, 1642. Lines 667, 728, and 1053 are **outside** MessageBubble (they belong to the search bar, cancel button, and message input field). **Only replace lines 1509, 1620, and 1642.** Do not touch 667, 728, or 1053.

- [ ] **Step 1: Confirm which lines are inside MessageBubble**

```bash
grep -n "messageBubbleText" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift
```

Expected: 6 hits. The MessageBubble struct starts at line 1377 — only hits at line 1509+ are inside it.

- [ ] **Step 2: Replace messageBubbleText at line ~1509 (text message body)**

Read lines 1505–1515 first to confirm context, then find:
```swift
                        .font(SanchrTypography.messageBubbleText)
```
in the message text body section (the one after `Text(message.text ?? "")` or equivalent) and replace with:
```swift
                        .font(bubbleFont)
```

Use the Edit tool with enough surrounding context to make the match unique. Read the file after editing to confirm.

- [ ] **Step 3: Replace messageBubbleText at line ~1620 (contact name fallback)**

Find the contact name label inside MessageBubble (around line 1620) and replace:
```swift
                        .font(SanchrTypography.messageBubbleText)
```
with:
```swift
                        .font(bubbleFont)
```

- [ ] **Step 4: Replace messageBubbleText at line ~1642 (location label fallback)**

Find the "Location" label inside MessageBubble (around line 1642) and replace:
```swift
                        .font(SanchrTypography.messageBubbleText)
```
with:
```swift
                        .font(bubbleFont)
```

- [ ] **Step 5: Verify exactly 3 replacements were made (3 hits remain at 667, 728, 1053)**

```bash
grep -n "messageBubbleText" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift
```

Expected: exactly 3 hits — at lines 667, 728, and 1053. If any of those three changed, revert and re-do.

- [ ] **Step 6: Replace bubbleMainRadius in bubbleShape (line ~1697)**

Find the `bubbleShape` computed property:
```swift
    private var bubbleShape: UnevenRoundedRectangle {
        let main = SanchrSpacing.bubbleMainRadius
        let tail = SanchrSpacing.bubbleTailRadius
```

Replace only the `main` assignment:
```swift
    private var bubbleShape: UnevenRoundedRectangle {
        let main = bubbleCornerRadius
        let tail = SanchrSpacing.bubbleTailRadius
```

Leave `SanchrSpacing.bubbleTailRadius` unchanged — the tail is a fixed geometry detail.

- [ ] **Step 7: Verify bubbleTailRadius is untouched**

```bash
grep -n "bubbleTailRadius" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift
```

Expected: 1 hit — `let tail = SanchrSpacing.bubbleTailRadius` (unchanged).

- [ ] **Step 8: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Sanchr-IOS/Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "$(cat <<'EOF'
feat(chat): apply font size and bubble style preferences in MessageBubble

Replaces hardcoded SanchrTypography.messageBubbleText with bubbleFont
(driven by @AppStorage sanchr.fontSize) and SanchrSpacing.bubbleMainRadius
with bubbleCornerRadius (driven by @AppStorage sanchr.chatBubbleStyle).
Changes take effect immediately when the user adjusts preferences.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
1. ✅ Font size changes chat text — Task 3 replaces messageBubbleText with bubbleFont
2. ✅ Bubble style changes corner radius — Task 3 replaces bubbleMainRadius with bubbleCornerRadius
3. ✅ Changes take effect immediately — @AppStorage is reactive; SwiftUI re-renders automatically
4. ✅ Persists across restart — @AppStorage backed by UserDefaults
5. ✅ "More" tile removed — Task 1 Step 5
6. ✅ AppearanceView mirrors fontSize on load and on change — Task 1 Steps 3 and 4

**Placeholder scan:** All steps contain exact code. No TBDs.

**Type consistency:** `bubbleFont: Font`, `bubbleCornerRadius: CGFloat` — consistent across Tasks 2 and 3. `storedFontSize: String` — consistent across Task 1 steps.
