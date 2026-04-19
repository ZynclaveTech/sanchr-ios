# ChatDetailView God-File Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decompose `ChatDetailView.swift` (2836 LOC) and `ChatDetailViewModel.swift` (1391 LOC) into 15 focused files, each with a single responsibility, with zero behavior change.

**Architecture:** Pure mechanical extraction. Extract sub-views into their own Swift files. Split the ViewModel into extension files grouped by concern. Main `ChatDetailView` becomes a thin composition root. Main `ChatDetailViewModel` stays one type, spread across extension files. No logic, no APIs, no UI change.

**Tech Stack:** Swift 5.9+, SwiftUI, `@Observable` macro (ChatDetailViewModel), Xcode, xcodebuild.

**Spec:** `docs/superpowers/specs/2026-04-20-chat-detail-god-file-refactor-design.md`

---

## Conventions (apply to every task)

- Repo root: `/Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS`
- All file paths below are relative to repo root
- After every extraction, the **build gate** is:
  ```bash
  cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
  timeout 180 xcodebuild build -scheme Sanchr -configuration Debug 2>&1 | \
  grep -E "error:" | grep -v "Provisioning profile"
  ```
  Expected: **no output** (zero Swift compilation errors). Provisioning errors are environment-specific and OK to ignore.
- After every extraction, run the existing test suite:
  ```bash
  cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
  timeout 300 xcodebuild test -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | \
  tail -30
  ```
  Expected: `** TEST SUCCEEDED **`
- Commit per task with message prefix `refactor(chat): ...`
- **No behavior changes allowed in this plan.** If you encounter a bug during extraction, flag it — do not fix it in-flight.
- Because this refactor has no new functionality, **TDD does not apply** in the classic sense. The test is the existing test suite + build gate. Do not invent tests for extraction steps.

---

## Phase 0: Dead Code Audit

### Task 0: Audit `ChatDetailView.swift` and `ChatDetailViewModel.swift` for dead code

**Files:**
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`
- Modify: `Features/Chats/Presentation/ChatDetailViewModel.swift`

**Context:** Per CLAUDE.md "Step 0" rule, remove dead state, unused methods, stale imports BEFORE any structural refactor. This preserves the signal-to-noise ratio of later commits.

- [ ] **Step 1: Find unused `@State` / `@StateObject` properties in `ChatDetailView.swift`**

For every `@State` / `@StateObject` / `@FocusState` property declared in `ChatDetailView` (lines 31–75), search for its use in the view body and methods:

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
# For each name, confirm it's used somewhere other than its declaration
grep -n "private var \(\w\+\)" Features/Chats/Presentation/ChatDetailView.swift | while read line; do
  name=$(echo "$line" | sed -n 's/.*private var \([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/p')
  count=$(grep -c "\b$name\b" Features/Chats/Presentation/ChatDetailView.swift)
  echo "$name: $count occurrences"
done
```

Expected: each name should appear ≥2 times (declaration + at least one use). Any property with count=1 is dead — delete it.

- [ ] **Step 2: Find unused private methods in `ChatDetailView.swift`**

```bash
grep -nE "^\s*private func [a-zA-Z_]" Features/Chats/Presentation/ChatDetailView.swift | while read line; do
  name=$(echo "$line" | sed -nE 's/.*private func ([a-zA-Z_][a-zA-Z0-9_]*).*/\1/p')
  count=$(grep -c "\b$name\b" Features/Chats/Presentation/ChatDetailView.swift)
  echo "$name: $count occurrences"
done
```

Any method with count=1 is dead — delete it.

- [ ] **Step 3: Repeat Steps 1–2 for `ChatDetailViewModel.swift`**

Same commands, target `Features/Chats/Presentation/ChatDetailViewModel.swift`.

- [ ] **Step 4: Remove unused imports**

Open each file and remove any `import` line whose symbols are not referenced in the file. Common culprits: `UIKit` when only SwiftUI is used, `Combine` after migration to `@Observable`.

Verify with:
```bash
grep -n "^import " Features/Chats/Presentation/ChatDetailView.swift
grep -n "^import " Features/Chats/Presentation/ChatDetailViewModel.swift
```

For each import, grep the file for a symbol typically provided by that framework. If no match, remove the import.

- [ ] **Step 5: Build gate**

Run the build gate command from Conventions. Expected: no output.

- [ ] **Step 6: Run existing tests**

Run the test command from Conventions. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailView.swift Features/Chats/Presentation/ChatDetailViewModel.swift && \
git commit -m "refactor(chat): Remove dead state, methods, and imports before god-file extraction

Per CLAUDE.md Step 0 rule: clean up dead code in ChatDetailView and
ChatDetailViewModel before the structural decomposition, so later
commits contain only extraction diffs."
```

- [ ] **Step 8: Report current LOC so subsequent phases have a baseline**

```bash
wc -l Features/Chats/Presentation/ChatDetailView.swift Features/Chats/Presentation/ChatDetailViewModel.swift
```

Record the numbers in the task report.

---

## Phase 1: Leaf Sub-View Extraction

Each task in this phase extracts a self-contained sub-struct that does not reference `ChatDetailView` private state. Risk is lowest here — if anything breaks, the issue is an import or access-level mistake, not SwiftUI state semantics.

### Task 1: Extract `MessageBubble` into its own file

**Files:**
- Create: `Features/Chats/Presentation/MessageBubble.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift` (remove extracted content)

**Context:** `MessageBubble` is a standalone `struct` at lines ~1711–2109 of `ChatDetailView.swift`. It has its own state and receives its inputs via parameters. Ideal first extraction.

- [ ] **Step 1: Locate the exact line range of `MessageBubble`**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
awk '/^struct MessageBubble: View \{/{print NR}' Features/Chats/Presentation/ChatDetailView.swift
```

Expected: single line number (the `struct MessageBubble` opening). Note it as `START`.

Find the matching closing brace of the struct:
```bash
awk 'NR>=START_LINE && /^}$/{print NR; exit}' Features/Chats/Presentation/ChatDetailView.swift
```
Replace `START_LINE` with the number from the previous command. Note result as `END`.

- [ ] **Step 2: Read the target range into memory**

```bash
sed -n "${START},${END}p" Features/Chats/Presentation/ChatDetailView.swift
```

Review the output: confirm it's the complete `MessageBubble` struct with no stray types.

- [ ] **Step 3: Identify imports required by `MessageBubble`**

`MessageBubble` uses SwiftUI and may reference `Message`, `SanchrTypography`, `Color.sanchrTextPrimary(…)`, etc. Read lines 1–10 of `ChatDetailView.swift`:

```bash
sed -n '1,10p' Features/Chats/Presentation/ChatDetailView.swift
```

The new file will need the same imports that are actually referenced by the extracted code. Minimal set (verify by scanning the extracted struct):
- `import SwiftUI`
- Any `import` that the extracted code clearly uses (e.g., `import Kingfisher` if used — check)

- [ ] **Step 4: Create the new file**

Create `Features/Chats/Presentation/MessageBubble.swift` with this shape:

```swift
import SwiftUI
// Add any other imports the extracted code references
// (inspect the extracted body for symbols like Kingfisher, UIKit, etc.)

// MARK: - MessageBubble
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

<PASTE LINES START..END FROM ChatDetailView.swift>
```

- [ ] **Step 5: Incremental build gate (compile only the new file with the project)**

Run the build gate from Conventions. If errors, they'll fall into these categories:
- **Missing import** — add it to the new file
- **`private` visibility** — a helper used by `MessageBubble` was `private` inside `ChatDetailView.swift` and is now unreachable. Change it to `fileprivate` is NOT an option (different file). Escalate these: either (a) move the helper along with `MessageBubble`, or (b) promote the helper to `internal` with `// visibility promoted for cross-file access` comment, or (c) if it's a nested type inside `MessageBubble`, no change needed.

- [ ] **Step 6: Remove extracted content from `ChatDetailView.swift`**

Delete lines `START..END` (inclusive) in `Features/Chats/Presentation/ChatDetailView.swift`. Use the Edit tool with a targeted `old_string` (the first 3 lines of the struct) + `new_string` (empty) strategy — or delete the block range directly.

- [ ] **Step 7: Build gate**

Run the build gate from Conventions. Expected: no output.

- [ ] **Step 8: Run existing tests**

Run the test command from Conventions. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Verify LOC**

```bash
wc -l Features/Chats/Presentation/MessageBubble.swift Features/Chats/Presentation/ChatDetailView.swift
```

Expected: `MessageBubble.swift` ≈ 400 LOC; `ChatDetailView.swift` dropped by ≈ 400.

- [ ] **Step 10: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/MessageBubble.swift Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "refactor(chat): Extract MessageBubble into its own file

Part of ChatDetailView god-file decomposition. Pure mechanical
extraction; no behavior change."
```

---

### Task 2: Extract `MediaBubbleImage` + `BubbleMediaLayout` + `BubbleImagePipeline`

**Files:**
- Create: `Features/Chats/Presentation/MediaBubbleImage.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Context:** `MediaBubbleImage` (≈ lines 2110–2404), `BubbleMediaLayout` enum (≈ line 2514), and `BubbleImagePipeline` enum (≈ line 2535) are tightly coupled — they belong in one file.

- [ ] **Step 1: Locate all three line ranges**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
grep -nE "^(private )?struct MediaBubbleImage|^private enum BubbleMediaLayout|^private enum BubbleImagePipeline" Features/Chats/Presentation/ChatDetailView.swift
```

Record the opening line of each. Find each matching close by scanning forward for the next top-level `}`.

- [ ] **Step 2: Read each range to verify contents**

```bash
sed -n "A,Bp" Features/Chats/Presentation/ChatDetailView.swift   # MediaBubbleImage
sed -n "C,Dp" Features/Chats/Presentation/ChatDetailView.swift   # BubbleMediaLayout
sed -n "E,Fp" Features/Chats/Presentation/ChatDetailView.swift   # BubbleImagePipeline
```

Replace A..F with actual line numbers.

- [ ] **Step 3: Create `Features/Chats/Presentation/MediaBubbleImage.swift`**

```swift
import SwiftUI
// Add any additional imports referenced by the extracted code
// (common: UIKit for UIImage, Kingfisher, AVFoundation if video thumbs used)

// MARK: - Media Bubble Image
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

<PASTE MediaBubbleImage struct>

// MARK: - Bubble Media Layout
<PASTE BubbleMediaLayout enum>

// MARK: - Bubble Image Pipeline
<PASTE BubbleImagePipeline enum>
```

Note: both enums are currently `private`. Since they're only referenced by `MediaBubbleImage` (which now lives in the same file), keep them `private`.

- [ ] **Step 4: Remove all three ranges from `ChatDetailView.swift`**

Delete the three ranges in reverse line order (highest line number first) so earlier line numbers stay valid.

- [ ] **Step 5: Build gate**

Run the build gate from Conventions. Expected: no output.

Common failure: `MediaBubbleImage` was marked `private` at the struct level but referenced by `MessageBubble` or the main view. If the build fails with "cannot find 'MediaBubbleImage'", promote its visibility from `private` to no modifier (module-internal) in the new file, and add a comment `// Visibility promoted during god-file extraction`.

- [ ] **Step 6: Run existing tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Verify LOC**

```bash
wc -l Features/Chats/Presentation/MediaBubbleImage.swift Features/Chats/Presentation/ChatDetailView.swift
```

Expected: `MediaBubbleImage.swift` ≈ 300 LOC.

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/MediaBubbleImage.swift Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "refactor(chat): Extract MediaBubbleImage and bubble layout/pipeline enums

Part of ChatDetailView god-file decomposition. Co-locates
MediaBubbleImage with its two helper enums. No behavior change."
```

---

### Task 3: Extract `ReactionPickerView` + `ReactionPillsView`

**Files:**
- Create: `Features/Chats/Presentation/ChatReactionsUI.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Context:** Two small sub-views at lines ≈ 2624 and ≈ 2655. Both are `private` in the current file — promote to module-internal on extraction because `ChatDetailView` will reference them from across the file boundary.

- [ ] **Step 1: Locate both ranges**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
grep -nE "^private struct ReactionPickerView|^private struct ReactionPillsView" Features/Chats/Presentation/ChatDetailView.swift
```

Find closing braces of each by scanning forward for top-level `}`.

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatReactionsUI.swift`**

```swift
import SwiftUI

// MARK: - Reaction Picker
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from `private` to module-internal for cross-file access.

struct ReactionPickerView: View {
    <PASTE BODY OF ORIGINAL ReactionPickerView>
}

// MARK: - Reaction Pills

struct ReactionPillsView: View {
    <PASTE BODY OF ORIGINAL ReactionPillsView>
}
```

Note: drop the `private` access modifier on both structs.

- [ ] **Step 3: Remove both ranges from `ChatDetailView.swift`**

Delete in reverse line order.

- [ ] **Step 4: Build gate**

Expected: no output.

- [ ] **Step 5: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatReactionsUI.swift Features/Chats/Presentation/ChatDetailView.swift
```

Expected: `ChatReactionsUI.swift` ≈ 90 LOC.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatReactionsUI.swift Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "refactor(chat): Extract ReactionPickerView and ReactionPillsView

Part of ChatDetailView god-file decomposition. No behavior change."
```

---

### Task 4: Extract leaf helpers into `ChatDetailHelpers.swift`

**Files:**
- Create: `Features/Chats/Presentation/ChatDetailHelpers.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Context:** Several small helper types and modifiers live at the tail of `ChatDetailView.swift`. They have no state dependency on the main view and belong in a shared helpers file:

- `LinkPreviewCard` (≈ line 2405)
- `SwipeToReplyWrapper` (≈ line 2574)
- `ChatViewerHUDModifier` (≈ line 2700)
- `ChatSearchFieldSurfaceModifier` (≈ line 2716)
- `NewContactPayload` (≈ line 2733)
- `GalleryIdentifiedURLBridge` (≈ line 2742)
- `ChatShareActivityView` (≈ line 2751)
- `BootstrapContactRepository` (≈ line 2765)
- `BootstrapMediaResolver` (≈ line 2797)
- `DeviceContactMatcher` (≈ line 2816)

- [ ] **Step 1: Locate every range**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
grep -nE "^(private )?(struct|class|final class|enum) (LinkPreviewCard|SwipeToReplyWrapper|ChatViewerHUDModifier|ChatSearchFieldSurfaceModifier|NewContactPayload|GalleryIdentifiedURLBridge|ChatShareActivityView|BootstrapContactRepository|BootstrapMediaResolver|DeviceContactMatcher)\b" Features/Chats/Presentation/ChatDetailView.swift
```

For each match, find its matching closing brace by scanning forward for the next top-level `}`.

- [ ] **Step 2: Inspect each range**

```bash
sed -n "S,Ep" Features/Chats/Presentation/ChatDetailView.swift
```

For every pair (S, E). Confirm each range is complete (no partial structs).

- [ ] **Step 3: Create `Features/Chats/Presentation/ChatDetailHelpers.swift`**

```swift
import SwiftUI
import UIKit
// Include every import used by the extracted types. Likely superset:
// import LinkPresentation, AVFoundation, Contacts, Combine

// MARK: - Link Preview Card
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

<PASTE LinkPreviewCard struct>

// MARK: - Swipe To Reply Wrapper

<PASTE SwipeToReplyWrapper struct>

// MARK: - Modifiers

<PASTE ChatViewerHUDModifier + ChatSearchFieldSurfaceModifier>

// MARK: - Helper Payload Types

<PASTE NewContactPayload>
<PASTE GalleryIdentifiedURLBridge>

// MARK: - Share Activity

<PASTE ChatShareActivityView>

// MARK: - Bootstrap Helpers

<PASTE BootstrapContactRepository>
<PASTE BootstrapMediaResolver>

// MARK: - Device Contact Matcher

<PASTE DeviceContactMatcher>
```

Preserve `private` → `fileprivate` or promote to module-internal based on call sites. When in doubt, promote: they're extracted from a private context and callers now live in sibling files.

- [ ] **Step 4: Remove all ranges from `ChatDetailView.swift` in reverse line order**

Delete highest-line range first so earlier line numbers remain valid.

- [ ] **Step 5: Build gate**

Expected: no output. If a helper is still marked `private` but referenced from the main view, promote visibility.

- [ ] **Step 6: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatDetailHelpers.swift Features/Chats/Presentation/ChatDetailView.swift
```

Expected: `ChatDetailHelpers.swift` ≈ 150 LOC.

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailHelpers.swift Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "refactor(chat): Extract leaf helpers (LinkPreview, SwipeToReply, modifiers, bootstrap types) into ChatDetailHelpers.swift

Part of ChatDetailView god-file decomposition. No behavior change."
```

### Phase 1 Checkpoint

- [ ] **Step 1: Confirm Phase 1 state**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
wc -l Features/Chats/Presentation/ChatDetailView.swift Features/Chats/Presentation/MessageBubble.swift Features/Chats/Presentation/MediaBubbleImage.swift Features/Chats/Presentation/ChatReactionsUI.swift Features/Chats/Presentation/ChatDetailHelpers.swift
```

Expected `ChatDetailView.swift` ≈ 1900 LOC (dropped from 2836). Four new files present.

- [ ] **Step 2: Smoke test (manual)**

If running interactively, open the app, load a conversation, scroll, react to a message, reply, open a photo in the viewer. All must behave identically. If running in headless/CI, skip this step.

---

## Phase 2: Composed View Extraction

Each task in this phase extracts a large piece of `ChatDetailView`'s `body` into a sibling view. These children receive `@Bindable var viewModel: ChatDetailViewModel` plus explicit `@Binding` parameters for state owned by the root. Coordinators (`galleryCoordinator`, `contactCoordinator`, `locationCoordinator`, `documentCoordinator`) stay on the root view and are passed in as plain references.

### Task 5: Extract `ChatDetailHeaderView`

**Files:**
- Create: `Features/Chats/Presentation/ChatDetailHeaderView.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Context:** The header UI + its support methods: `headerActionButton`, `headerMenuButton`, `toggleArchivedState`, `hideConversationFromDevice`, `refreshConversationState`, `loadHeaderPreferences`, plus the header `@State` `isConversationArchived`.

- [ ] **Step 1: Identify header state and functions**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
grep -nE "headerActionButton|headerMenuButton|toggleArchivedState|hideConversationFromDevice|refreshConversationState|loadHeaderPreferences|isConversationArchived|conversationActionErrorMessage" Features/Chats/Presentation/ChatDetailView.swift
```

Record all matches. Identify the contiguous header view block in `body` (usually a `ToolbarItem` or a `HStack` at the top of the view hierarchy).

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatDetailHeaderView.swift`**

```swift
import SwiftUI

// MARK: - Chat Detail Header
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

@MainActor
struct ChatDetailHeaderView: View {
    @Bindable var viewModel: ChatDetailViewModel
    @Binding var isConversationArchived: Bool
    @Binding var conversationActionErrorMessage: String?
    @Binding var showConversationInfo: Bool
    let onDismiss: () -> Void

    var body: some View {
        <PASTE HEADER HSTACK / TOOLBAR CONTENT FROM ChatDetailView.body>
    }

    <PASTE headerActionButton>
    <PASTE headerMenuButton>
    <PASTE toggleArchivedState (async)>
    <PASTE hideConversationFromDevice (async)>
    <PASTE refreshConversationState (async)>
    <PASTE loadHeaderPreferences (async)>
}
```

- [ ] **Step 3: Replace header block in `ChatDetailView.body`**

Replace the extracted toolbar/HStack with:

```swift
ChatDetailHeaderView(
    viewModel: viewModel,
    isConversationArchived: $isConversationArchived,
    conversationActionErrorMessage: $conversationActionErrorMessage,
    showConversationInfo: $showConversationInfo,
    onDismiss: { dismiss() }
)
```

- [ ] **Step 4: Remove extracted methods from `ChatDetailView.swift`**

Delete `headerActionButton`, `headerMenuButton`, `toggleArchivedState`, `hideConversationFromDevice`, `refreshConversationState`, `loadHeaderPreferences`.

- [ ] **Step 5: Build gate**

Expected: no output.

Common failure: `viewModel.debouncedSync(...)` or similar calls may reference `settingsDataSource` obtained from the root's `@Environment`. If the header view needs environment access, add `@Environment(DependencyContainer.self) private var container` to `ChatDetailHeaderView` (same as the parent).

- [ ] **Step 6: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatDetailHeaderView.swift
```

Expected ≈ 200 LOC.

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailHeaderView.swift Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "refactor(chat): Extract ChatDetailHeaderView

Part of ChatDetailView god-file decomposition. Header and its action
methods (archive, hide, refresh) moved to dedicated subview.
No behavior change."
```

---

### Task 6: Extract `ChatTranscriptView`

**Files:**
- Create: `Features/Chats/Presentation/ChatTranscriptView.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Context:** The message-list rendering section plus scroll-coordination state and methods:
- State: `transcriptScrollSequence`, `transcriptScrollCommand`, `hasPresentedInitialTranscript`, `hasScheduledDeferredEntryTasks`, `isScrolledToBottom`, `newMessageCountWhileScrolled`
- Methods: `nextTranscriptScrollSequence`, `issueTranscriptScroll`, `handleInitialTranscriptPresentation`, `scheduleDeferredEntryTasksIfNeeded`, `markConversationAsReadIfNeeded`, `dateSeparator`

- [ ] **Step 1: Identify the transcript `ScrollView` or `List` block in `body`**

Search for the transcript presentation. It's usually `ScrollViewReader { proxy in ScrollView { LazyVStack { ForEach(viewModel.messageSections) … } } }`:

```bash
grep -nE "ScrollViewReader|LazyVStack|ForEach.*messageSection|ForEach.*messages" Features/Chats/Presentation/ChatDetailView.swift | head -20
```

Identify the contiguous range.

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatTranscriptView.swift`**

```swift
import SwiftUI

// MARK: - Chat Transcript
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

@MainActor
struct ChatTranscriptView: View {
    @Bindable var viewModel: ChatDetailViewModel
    @ObservedObject var galleryCoordinator: MediaGalleryCoordinator
    @ObservedObject var contactCoordinator: ContactActionCoordinator
    @Binding var isScrolledToBottom: Bool
    @Binding var newMessageCountWhileScrolled: Int
    @Binding var transcriptScrollSequence: UInt64
    @Binding var transcriptScrollCommand: TranscriptScrollCommand?
    @Binding var hasPresentedInitialTranscript: Bool
    @Binding var hasScheduledDeferredEntryTasks: Bool

    var body: some View {
        <PASTE TRANSCRIPT SCROLLVIEW BLOCK>
    }

    <PASTE dateSeparator>
    <PASTE nextTranscriptScrollSequence>
    <PASTE issueTranscriptScroll>
    <PASTE handleInitialTranscriptPresentation>
    <PASTE scheduleDeferredEntryTasksIfNeeded>
    <PASTE markConversationAsReadIfNeeded (async)>
}
```

Note: `TranscriptScrollCommand` is a type defined somewhere in the project — verify with `grep -rn "enum TranscriptScrollCommand\|struct TranscriptScrollCommand"` and make sure its visibility allows cross-file use. If it was declared `private` in `ChatDetailView.swift`, promote it.

- [ ] **Step 3: Replace the transcript block in `ChatDetailView.body`**

```swift
ChatTranscriptView(
    viewModel: viewModel,
    galleryCoordinator: galleryCoordinator,
    contactCoordinator: contactCoordinator,
    isScrolledToBottom: $isScrolledToBottom,
    newMessageCountWhileScrolled: $newMessageCountWhileScrolled,
    transcriptScrollSequence: $transcriptScrollSequence,
    transcriptScrollCommand: $transcriptScrollCommand,
    hasPresentedInitialTranscript: $hasPresentedInitialTranscript,
    hasScheduledDeferredEntryTasks: $hasScheduledDeferredEntryTasks
)
```

- [ ] **Step 4: Remove extracted methods from `ChatDetailView.swift`**

Delete `dateSeparator`, `nextTranscriptScrollSequence`, `issueTranscriptScroll`, `handleInitialTranscriptPresentation`, `scheduleDeferredEntryTasksIfNeeded`, `markConversationAsReadIfNeeded`.

- [ ] **Step 5: Build gate**

Expected: no output. If `TranscriptScrollCommand` visibility error appears, promote it.

- [ ] **Step 6: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatTranscriptView.swift
```

Expected ≈ 450 LOC.

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatTranscriptView.swift Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "refactor(chat): Extract ChatTranscriptView

Message list, scroll coordination, and read-receipt trigger moved
into dedicated subview. No behavior change."
```

---

### Task 7: Extract `ChatInputBarView`

**Files:**
- Create: `Features/Chats/Presentation/ChatInputBarView.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Context:** Input field + 8 attachment-related picker flags + voice recording integration.
- State: `isInputFocused` (`@FocusState`), `showAttachmentPicker`, `showCameraCapture`, `showEmojiPicker`, `showStickerPicker`, `showPhotosPicker`, `showFileImporter`, `showContactPicker`, `selectedPhotoItems`, `voicePlayback`
- Methods referenced: `makeAttachmentSendContext`, `handleSelectedPhoto`, `commitPendingMediaSend`, `commitImageEdit`, `consumePendingChatAttachmentIfNeeded` (these may need to stay on root; pass as closures or keep the sheets on root)

**Design decision:** keep the **sheets** (picker presentations) on the root view and have the input bar emit simple intent closures (`onAttachmentTap: () -> Void`, etc.). The flags move to root bindings. This avoids state migration risk on picker presentation.

- [ ] **Step 1: Identify the input bar block in `body`**

Search for the input field / send button UI:
```bash
grep -nE "TextField|sendButton|attachmentButton|VoiceRecordingButton|isInputFocused" Features/Chats/Presentation/ChatDetailView.swift | head -20
```

Find the contiguous input-bar region (typically at the bottom of the `VStack` in body).

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatInputBarView.swift`**

```swift
import SwiftUI
import PhotosUI

// MARK: - Chat Input Bar
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

@MainActor
struct ChatInputBarView: View {
    @Bindable var viewModel: ChatDetailViewModel
    @FocusState.Binding var isInputFocused: Bool
    @Binding var voicePlayback: VoicePlaybackController
    let onAttachmentTap: () -> Void
    let onCameraTap: () -> Void
    let onEmojiTap: () -> Void
    let onStickerTap: () -> Void

    var body: some View {
        <PASTE INPUT BAR HSTACK/VSTACK>
    }
}
```

The picker flags (`showAttachmentPicker`, etc.) stay on the root view. The root wires `onAttachmentTap: { showAttachmentPicker = true }`.

- [ ] **Step 3: Replace the input bar block in `ChatDetailView.body`**

```swift
ChatInputBarView(
    viewModel: viewModel,
    isInputFocused: $isInputFocused,
    voicePlayback: $voicePlayback,
    onAttachmentTap: { showAttachmentPicker = true },
    onCameraTap: { showCameraCapture = true },
    onEmojiTap: { showEmojiPicker = true },
    onStickerTap: { showStickerPicker = true }
)
```

The sheets (`.sheet(isPresented: $showAttachmentPicker) { ... }`) stay on the root.

- [ ] **Step 4: Build gate**

Expected: no output.

- [ ] **Step 5: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatInputBarView.swift
```

Expected ≈ 250 LOC.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatInputBarView.swift Features/Chats/Presentation/ChatDetailView.swift && \
git commit -m "refactor(chat): Extract ChatInputBarView

Input field + attachment menu moved to dedicated subview. Picker
presentation remains on root; subview emits intent closures.
No behavior change."
```

---

### Task 8: Extract message context menu and format helpers into `ChatMessageContextMenu.swift`

**Files:**
- Create: `Features/Chats/Presentation/ChatMessageContextMenu.swift`
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Context:** The long-press context menu + reply-preview + format helpers:
- `messageContextMenu(_:)` (≈ line 1109)
- `replyPreviewText(_:)` (≈ line 1465)
- `systemEventLabel(_:)` (≈ line 1823)
- `formatDuration(_:)` (≈ line 1970)
- `formatFileSize(_:)` (≈ line 1976)
- `contactFallbackBubble(name:)` (≈ line 1981)
- `locationFallbackBubble(latitude:longitude:)` (≈ line 2003)

These are helpers used only by bubble rendering and the context menu. They don't need view identity; make them module-level or grouped in a struct namespace.

- [ ] **Step 1: Locate each helper**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
grep -nE "messageContextMenu|replyPreviewText|systemEventLabel|formatDuration|formatFileSize|contactFallbackBubble|locationFallbackBubble" Features/Chats/Presentation/ChatDetailView.swift
```

Record line numbers.

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatMessageContextMenu.swift`**

```swift
import SwiftUI

// MARK: - Message Context Menu + Helpers
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

@MainActor
enum ChatMessageContextMenu {
    @ViewBuilder
    static func menu(
        for message: Message,
        viewModel: ChatDetailViewModel,
        onReply: @escaping (Message) -> Void,
        onForward: @escaping (Message) -> Void,
        onDelete: @escaping (Message) -> Void
    ) -> some View {
        <PASTE messageContextMenu BODY, adapted to static + closure callbacks>
    }
}

// MARK: - Format Helpers

enum ChatFormatting {
    static func replyPreviewText(_ message: Message) -> String {
        <PASTE replyPreviewText BODY>
    }

    static func systemEventLabel(_ event: Message.SystemEvent) -> String {
        <PASTE systemEventLabel BODY>
    }

    static func duration(_ seconds: Double) -> String {
        <PASTE formatDuration BODY>
    }

    static func fileSize(_ bytes: Int64) -> String {
        <PASTE formatFileSize BODY>
    }
}

// MARK: - Fallback Bubbles

@MainActor
enum ChatFallbackBubble {
    @ViewBuilder
    static func contact(name: String) -> some View {
        <PASTE contactFallbackBubble BODY>
    }

    @ViewBuilder
    static func location(latitude: Double, longitude: Double) -> some View {
        <PASTE locationFallbackBubble BODY>
    }
}
```

- [ ] **Step 3: Update call sites**

In `ChatDetailView.swift` (and any other file that used these helpers — likely only `ChatDetailView.swift`, `MessageBubble.swift`, and `ChatTranscriptView.swift`):

- `messageContextMenu(m)` → `ChatMessageContextMenu.menu(for: m, viewModel: viewModel, onReply: { ... }, onForward: { ... }, onDelete: { ... })`
- `replyPreviewText(m)` → `ChatFormatting.replyPreviewText(m)`
- `systemEventLabel(e)` → `ChatFormatting.systemEventLabel(e)`
- `formatDuration(s)` → `ChatFormatting.duration(s)`
- `formatFileSize(b)` → `ChatFormatting.fileSize(b)`
- `contactFallbackBubble(name: n)` → `ChatFallbackBubble.contact(name: n)`
- `locationFallbackBubble(latitude: lat, longitude: lng)` → `ChatFallbackBubble.location(latitude: lat, longitude: lng)`

Use grep + multi-file edit to update all call sites:
```bash
grep -rn "messageContextMenu\|replyPreviewText\|systemEventLabel\|formatDuration\|formatFileSize\|contactFallbackBubble\|locationFallbackBubble" Features/Chats/Presentation/
```

- [ ] **Step 4: Remove the extracted helpers from `ChatDetailView.swift`**

Delete all seven methods in reverse line order.

- [ ] **Step 5: Build gate**

Expected: no output. Expect to fix some call-site signature mismatches (e.g., `messageContextMenu` originally took `(Message)` and returned `some View`; now it needs closure callbacks for reply/forward/delete actions that previously closed over `self`).

- [ ] **Step 6: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatMessageContextMenu.swift Features/Chats/Presentation/ChatDetailView.swift
```

Expected: `ChatMessageContextMenu.swift` ≈ 200 LOC; `ChatDetailView.swift` down significantly.

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatMessageContextMenu.swift Features/Chats/Presentation/ && \
git commit -m "refactor(chat): Extract message context menu and format helpers

messageContextMenu, replyPreviewText, systemEventLabel, formatDuration,
formatFileSize, contactFallbackBubble, locationFallbackBubble moved to
namespaced enums in ChatMessageContextMenu.swift. No behavior change."
```

### Phase 2 Checkpoint

- [ ] **Step 1: Confirm Phase 2 state**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
wc -l Features/Chats/Presentation/ChatDetailView.swift \
     Features/Chats/Presentation/ChatDetailHeaderView.swift \
     Features/Chats/Presentation/ChatTranscriptView.swift \
     Features/Chats/Presentation/ChatInputBarView.swift \
     Features/Chats/Presentation/ChatMessageContextMenu.swift
```

Expected `ChatDetailView.swift` ≈ 350–450 LOC.

- [ ] **Step 2: Smoke test (manual)**

Send a message, receive one, long-press to see context menu, reply, forward, delete. All must behave identically.

---

## Phase 3: ViewModel Extension Split

Each task extracts one `// MARK:` group from `ChatDetailViewModel.swift` into a Swift extension in a sibling file. Swift extensions share the type's stored properties and private members (within the same module), so no access changes are needed.

### Task 9: Extract `ChatDetailViewModel+Messages.swift`

**Files:**
- Create: `Features/Chats/Presentation/ChatDetailViewModel+Messages.swift`
- Modify: `Features/Chats/Presentation/ChatDetailViewModel.swift`

**Context:** Message-lifecycle methods: load, load-more, receive/decrypt, retry, delete. These live in MARK sections: `Load Messages`, `Receive & Decrypt Incoming Message`, `Load More (Pagination)`, `Retry Failed Message`, `Delete Message`.

- [ ] **Step 1: Identify the contiguous method ranges**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
grep -nE "// MARK: - (Load Messages|Receive & Decrypt|Load More|Retry Failed|Delete Message)" Features/Chats/Presentation/ChatDetailViewModel.swift
```

Record line numbers. Each MARK starts a section; the section ends at the next MARK or the closing `}` of the class.

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatDetailViewModel+Messages.swift`**

```swift
import Foundation
// Include any additional imports referenced by the extracted methods.
// Likely: import OSLog (if SanchrLogger is used), any model types.

// MARK: - Message Lifecycle
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {
    // MARK: - Load Messages
    <PASTE LOAD MESSAGES METHODS>

    // MARK: - Receive & Decrypt Incoming Message
    <PASTE RECEIVE METHODS>

    // MARK: - Load More (Pagination)
    <PASTE LOAD MORE METHODS>

    // MARK: - Retry Failed Message
    <PASTE RETRY METHODS>

    // MARK: - Delete Message
    <PASTE DELETE METHODS>
}
```

Do NOT change any `private` or `public` modifier. Extensions in the same module have full access.

- [ ] **Step 3: Remove the five MARK sections from `ChatDetailViewModel.swift`**

Delete in reverse line order.

- [ ] **Step 4: Build gate**

Expected: no output. If you see "extension must be declared at the top level of a file" or "cannot find type ChatDetailViewModel in scope", the extension was accidentally nested or the file is missing `import Foundation`/correct type visibility.

- [ ] **Step 5: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatDetailViewModel+Messages.swift Features/Chats/Presentation/ChatDetailViewModel.swift
```

Expected: `+Messages.swift` ≈ 300 LOC.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailViewModel+Messages.swift Features/Chats/Presentation/ChatDetailViewModel.swift && \
git commit -m "refactor(chat): Split ViewModel — extract message lifecycle into +Messages extension

Load, load-more, receive/decrypt, retry, delete moved to a dedicated
extension file. Type unchanged; extension shares access. No behavior change."
```

---

### Task 10: Extract `ChatDetailViewModel+Send.swift`

**Files:**
- Create: `Features/Chats/Presentation/ChatDetailViewModel+Send.swift`
- Modify: `Features/Chats/Presentation/ChatDetailViewModel.swift`

**Context:** Send-path methods: text send, media send, forward, attachment routing. MARK sections: `Send Message (E2EE)`, `Media Send`, `Forward Message`, `Attachment Intent Routing`. Also move the nested `AttachmentSendContext` struct.

- [ ] **Step 1: Locate ranges and the nested `AttachmentSendContext` struct**

```bash
grep -nE "// MARK: - (Send Message|Media Send|Forward Message|Attachment Intent Routing)|struct AttachmentSendContext" Features/Chats/Presentation/ChatDetailViewModel.swift
```

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatDetailViewModel+Send.swift`**

```swift
import Foundation
// Import additional frameworks referenced by send methods (e.g., AVFoundation for media duration).

// MARK: - Send Pipeline
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {
    struct AttachmentSendContext {
        <PASTE ORIGINAL STRUCT FIELDS>
    }

    // MARK: - Send Message (E2EE)
    <PASTE SEND METHODS>

    // MARK: - Media Send
    <PASTE MEDIA SEND METHODS>

    // MARK: - Forward Message
    <PASTE FORWARD METHODS>

    // MARK: - Attachment Intent Routing
    <PASTE ATTACHMENT INTENT METHODS>
}
```

- [ ] **Step 3: Remove extracted sections from `ChatDetailViewModel.swift`**

Including the `AttachmentSendContext` struct.

- [ ] **Step 4: Build gate**

Expected: no output. Verify `ChatDetailView.swift` still calls `viewModel.makeAttachmentSendContext()` correctly — `AttachmentSendContext` is still nested in `ChatDetailViewModel`, just declared in an extension.

- [ ] **Step 5: Run tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Verify LOC**

```bash
wc -l Features/Chats/Presentation/ChatDetailViewModel+Send.swift Features/Chats/Presentation/ChatDetailViewModel.swift
```

Expected: `+Send.swift` ≈ 350 LOC.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailViewModel+Send.swift Features/Chats/Presentation/ChatDetailViewModel.swift && \
git commit -m "refactor(chat): Split ViewModel — extract send pipeline into +Send extension

Send (E2EE), media send, forward, attachment routing moved to a
dedicated extension file. AttachmentSendContext moved with it.
No behavior change."
```

---

### Task 11: Extract `ChatDetailViewModel+Reactions.swift`

**Files:**
- Create: `Features/Chats/Presentation/ChatDetailViewModel+Reactions.swift`
- Modify: `Features/Chats/Presentation/ChatDetailViewModel.swift`

**Context:** MARK sections `Reactions` and `Reply State`. Reply state is coupled to reactions because both modify existing messages.

- [ ] **Step 1: Locate ranges**

```bash
grep -nE "// MARK: - (Reactions|Reply State)" Features/Chats/Presentation/ChatDetailViewModel.swift
```

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatDetailViewModel+Reactions.swift`**

```swift
import Foundation

// MARK: - Reactions + Reply
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {
    // MARK: - Reactions
    <PASTE REACTIONS METHODS>

    // MARK: - Reply State
    <PASTE REPLY STATE METHODS>
}
```

- [ ] **Step 3: Remove extracted sections from the source**

- [ ] **Step 4: Build gate + tests + commit**

Expected: build clean; `** TEST SUCCEEDED **`.

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailViewModel+Reactions.swift Features/Chats/Presentation/ChatDetailViewModel.swift && \
git commit -m "refactor(chat): Split ViewModel — extract reactions and reply state into +Reactions extension

No behavior change."
```

---

### Task 12: Extract `ChatDetailViewModel+Realtime.swift`

**Files:**
- Create: `Features/Chats/Presentation/ChatDetailViewModel+Realtime.swift`
- Modify: `Features/Chats/Presentation/ChatDetailViewModel.swift`

**Context:** MARK section `Typing Indicator`. Also includes any presence/receipt-broadcast logic handled in the ViewModel.

- [ ] **Step 1: Locate range**

```bash
grep -nE "// MARK: - Typing Indicator" Features/Chats/Presentation/ChatDetailViewModel.swift
```

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatDetailViewModel+Realtime.swift`**

```swift
import Foundation

// MARK: - Realtime
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {
    // MARK: - Typing Indicator
    <PASTE TYPING METHODS>
}
```

- [ ] **Step 3: Remove extracted section from the source**

- [ ] **Step 4: Build gate + tests + commit**

Expected: build clean; `** TEST SUCCEEDED **`.

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailViewModel+Realtime.swift Features/Chats/Presentation/ChatDetailViewModel.swift && \
git commit -m "refactor(chat): Split ViewModel — extract typing indicator into +Realtime extension

No behavior change."
```

---

### Task 13: Extract `ChatDetailViewModel+Search.swift`

**Files:**
- Create: `Features/Chats/Presentation/ChatDetailViewModel+Search.swift`
- Modify: `Features/Chats/Presentation/ChatDetailViewModel.swift`

**Context:** MARK section `Search` (≈ line 1183) — the *methods*, not the state fields. State fields for search (lines ~71–77 inside the `Search State` MARK) stay on the main class because they are stored properties.

- [ ] **Step 1: Locate the search methods block**

```bash
grep -nE "// MARK: - Search$" Features/Chats/Presentation/ChatDetailViewModel.swift
```

Note: the `Search State` MARK at line ~71 should NOT be extracted — it contains stored properties.

- [ ] **Step 2: Create `Features/Chats/Presentation/ChatDetailViewModel+Search.swift`**

```swift
import Foundation

// MARK: - Search
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {
    // MARK: - Search
    <PASTE SEARCH METHODS>
}
```

- [ ] **Step 3: Remove the extracted method section from the source**

Leave the `Search State` stored-property section in place.

- [ ] **Step 4: Build gate + tests + commit**

Expected: build clean; `** TEST SUCCEEDED **`.

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Features/Chats/Presentation/ChatDetailViewModel+Search.swift Features/Chats/Presentation/ChatDetailViewModel.swift && \
git commit -m "refactor(chat): Split ViewModel — extract search logic into +Search extension

Search stored-property state remains on the main class; search methods
move to extension. No behavior change."
```

### Phase 3 Checkpoint

- [ ] **Step 1: Final LOC audit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
wc -l Features/Chats/Presentation/ChatDetailView.swift \
     Features/Chats/Presentation/ChatDetailHeaderView.swift \
     Features/Chats/Presentation/ChatTranscriptView.swift \
     Features/Chats/Presentation/ChatInputBarView.swift \
     Features/Chats/Presentation/ChatMessageContextMenu.swift \
     Features/Chats/Presentation/MessageBubble.swift \
     Features/Chats/Presentation/MediaBubbleImage.swift \
     Features/Chats/Presentation/ChatReactionsUI.swift \
     Features/Chats/Presentation/ChatDetailHelpers.swift \
     Features/Chats/Presentation/ChatDetailViewModel.swift \
     Features/Chats/Presentation/ChatDetailViewModel+Messages.swift \
     Features/Chats/Presentation/ChatDetailViewModel+Send.swift \
     Features/Chats/Presentation/ChatDetailViewModel+Reactions.swift \
     Features/Chats/Presentation/ChatDetailViewModel+Realtime.swift \
     Features/Chats/Presentation/ChatDetailViewModel+Search.swift
```

Expected: every file ≤ 450 LOC. `ChatDetailView.swift` ≤ 450 LOC. `ChatDetailViewModel.swift` ≤ 300 LOC.

- [ ] **Step 2: Full test run**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
timeout 300 xcodebuild test -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Manual smoke test**

Open the app. For one conversation verify:
- Header avatar, name, actions (archive, hide, refresh) render and work
- Transcript loads, scrolls, shows date separators, marks read on scroll-to-bottom
- Send text message succeeds
- Send photo via attachment menu succeeds
- Send voice message succeeds
- React to a message
- Reply to a message
- Forward a message
- Delete a message
- Search in chat finds results
- Open conversation info sheet

No regressions allowed. If anything misbehaves, bisect via `git log --oneline` to find the offending commit.

- [ ] **Step 4: Summary commit**

No new files; just a tracking commit with an `--allow-empty` tag, or skip and rely on the per-task commits. If the team prefers a summary, use:

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git commit --allow-empty -m "refactor(chat): Complete ChatDetailView god-file refactor

ChatDetailView.swift:      2836 -> ~400 LOC
ChatDetailViewModel.swift: 1391 -> ~250 LOC
13 new files, each <= 450 LOC, no behavior change.

See docs/superpowers/plans/2026-04-20-chat-detail-god-file-refactor.md"
```

---

## Rollback Strategy

If any phase breaks production behavior that the test suite did not catch:

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git log --oneline | grep "refactor(chat)"
# Identify the first bad commit
git revert <SHA>..HEAD
```

Because every task produces an independently-bisectable commit, reverts are surgical.

---

## Summary

13 new files extracted + 2 slimmed files + 1 dead-code cleanup commit = 14 commits across 3 phases. Each phase enforces CLAUDE.md's "≤5 files per phase" rule. Each task has a build-gate and test-gate before commit. No behavior changes, no new APIs, no test additions.
