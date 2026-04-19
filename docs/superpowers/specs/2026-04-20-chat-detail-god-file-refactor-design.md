# ChatDetailView God-File Refactor — Design Spec

**Date:** 2026-04-20
**Scope:** ChatDetailView.swift (2836 LOC) and ChatDetailViewModel.swift (1391 LOC)
**Type:** Structural refactor — extraction only, zero behavior changes

---

## Goal

Decompose two god-files in the chat feature into 15 focused files, each with a single clear responsibility. Preserve all existing behavior. Improve testability of the ViewModel by splitting concerns into separate extension files.

## Non-Goals

- No logic changes, no API changes, no UI changes
- No introduction of new features
- No refactor of ConversationInfoView or ChatsListView (separate specs)
- No rewrite of message-rendering pipeline internals

## Motivation

Both files violate single-responsibility and exceed a size where any developer (human or AI) can hold the full context in working memory. ChatDetailView mixes header, transcript, input bar, attachment pipeline, realtime event handling, and a half-dozen sub-views in one struct. ChatDetailViewModel mixes send, receive, search, reactions, typing, pagination, and media in one `@MainActor` class. Current structure blocks:

- Reliable AI-assisted edits (context window thrashing)
- Independent unit testing of ViewModel concerns
- Parallel development (merge conflicts on every feature touch)

## Architecture

The refactor is **pure mechanical extraction**. The main `ChatDetailView` struct becomes a thin composition root that wires together purpose-built subviews. The main `ChatDetailViewModel` class stays as a single type, but its methods are partitioned across extension files grouped by concern.

**Why extensions for the ViewModel (not separate types):** SwiftUI `@Observable` semantics work on a single type. Splitting into multiple coordinator classes would force plumbing changes at every call site in the view. Extensions in separate files give us file-level isolation of concerns without touching the public API.

**Why child views for the View:** SwiftUI composition is the idiomatic way to decompose a large view. Each child view owns only the state it needs and receives the rest via `@Bindable` or explicit bindings.

## File Layout

### View Layer

| New File | Target LOC | Responsibilities | Extracted From (source line ranges) |
|---|---|---|---|
| `ChatDetailView.swift` (slimmed) | ~350 | Top-level layout; sheet/picker presentation; `@StateObject` coordinators; composition of child views | Main struct body; lines 31–1710 (reduced) |
| `ChatDetailHeaderView.swift` | ~200 | Header with avatar/name/security badge; menu buttons; archive/hide/refresh actions; header prefs | `headerActionButton`, `headerMenuButton`, `toggleArchivedState`, `hideConversationFromDevice`, `refreshConversationState`, `loadHeaderPreferences` |
| `ChatTranscriptView.swift` | ~450 | Message list rendering; scroll coordination; date separators; read-receipt triggering | `dateSeparator`, scroll state (`transcriptScrollSequence`, `transcriptScrollCommand`, `hasPresentedInitialTranscript`, `hasScheduledDeferredEntryTasks`), `nextTranscriptScrollSequence`, `issueTranscriptScroll`, `handleInitialTranscriptPresentation`, `scheduleDeferredEntryTasksIfNeeded`, `markConversationAsReadIfNeeded`, `isScrolledToBottom`, `newMessageCountWhileScrolled` |
| `ChatInputBarView.swift` | ~250 | Input field, send button, attachment menu, 8 picker-visibility flags, `@FocusState` | Input UI section; `showAttachmentPicker`, `showCameraCapture`, `showEmojiPicker`, `showStickerPicker`, `showPhotosPicker`, `showFileImporter`, `showContactPicker`, `isInputFocused`, `selectedPhotoItems` |
| `ChatMessageContextMenu.swift` | ~200 | Long-press context menu for a message; reply preview; system-event labels | `messageContextMenu(_:)`, `replyPreviewText`, `systemEventLabel`, `formatDuration`, `formatFileSize`, `contactFallbackBubble`, `locationFallbackBubble` |
| `MessageBubble.swift` | ~400 | The `MessageBubble` struct as-is | Lines 1711–2109 |
| `MediaBubbleImage.swift` | ~300 | Media bubble with image/video thumbnail pipeline | Lines 2110–2404 + `BubbleMediaLayout` (2514) + `BubbleImagePipeline` (2535) |
| `ChatReactionsUI.swift` | ~90 | `ReactionPickerView` + `ReactionPillsView` | Lines 2622–2699 |
| `ChatDetailHelpers.swift` | ~150 | `LinkPreviewCard`, `SwipeToReplyWrapper`, `ChatViewerHUDModifier`, `ChatSearchFieldSurfaceModifier`, `NewContactPayload`, `GalleryIdentifiedURLBridge`, `ChatShareActivityView`, `BootstrapContactRepository`, `BootstrapMediaResolver`, `DeviceContactMatcher` | Lines 2405–2513, 2574–2835 |

### ViewModel Layer

| New File | Target LOC | Responsibilities | Extracted From (existing MARK sections) |
|---|---|---|---|
| `ChatDetailViewModel.swift` (slimmed) | ~250 | Type declaration, stored properties, init, conversation lifecycle, `MessageSection`, DTOs (`GallerySeed`, `GalleryItem`) | `MARK: - State`, `MARK: - Search State` (fields only), `MARK: - Bubble-tap routing`, `MARK: - Conversation Lifecycle`; DTOs at lines 1376–1398 |
| `ChatDetailViewModel+Messages.swift` | ~300 | Load, load-more, receive & decrypt, retry, delete | `MARK: - Load Messages`, `MARK: - Receive & Decrypt Incoming Message`, `MARK: - Load More (Pagination)`, `MARK: - Retry Failed Message`, `MARK: - Delete Message` |
| `ChatDetailViewModel+Send.swift` | ~350 | Send message (E2EE), media send, forward, attachment routing, `AttachmentSendContext` | `MARK: - Send Message (E2EE)`, `MARK: - Media Send`, `MARK: - Forward Message`, `MARK: - Attachment Intent Routing` |
| `ChatDetailViewModel+Reactions.swift` | ~120 | Reactions + reply state | `MARK: - Reactions`, `MARK: - Reply State` |
| `ChatDetailViewModel+Realtime.swift` | ~180 | Typing indicator send/receive; presence updates | `MARK: - Typing Indicator` |
| `ChatDetailViewModel+Search.swift` | ~200 | Search execution, result navigation, highlight | `MARK: - Search` (logic) |

### Total

- **Before:** 2 files, 4227 LOC combined
- **After:** 15 files, each under ~450 LOC

## Data Flow

No change. ChatDetailView still owns `@State private var viewModel = ChatDetailViewModel()` and passes it down to child views as `@Bindable` or via explicit bindings. All `@StateObject` coordinators (gallery, contact, location, document) remain on the root view because they must survive child-view lifecycle events.

Cross-file communication inside the ViewModel uses normal `self.` method calls — extensions share the same type identity.

## Error Handling

No change. All existing `do/catch` blocks and error-propagation paths remain exactly as written. This refactor does not introduce or remove any error paths.

## Testing Strategy

**Baseline:** Run existing test suite before any extraction. Every test must still pass after each commit in the refactor sequence.

**Gate between phases:** `xcodebuild build -scheme Sanchr -configuration Debug` must produce zero Swift compilation errors before moving to the next phase.

**New tests (optional, post-refactor):** Once the ViewModel is split, each extension file becomes a natural target for focused unit tests. These are NOT in scope for this refactor but are unblocked by it.

## Execution Sequence

Per CLAUDE.md phased-execution rule (≤5 files per phase), the refactor splits into four phases. Each phase ends with a type-check gate and its own commit(s).

**Phase 0 — Dead Code Audit (Step 0 rule):**
Before any extraction, audit both files for unused `@State` properties, unused helper methods, unused imports, unreachable branches. Commit cleanup separately. This is a prerequisite, not an extraction phase.

**Phase 1 — Leaf sub-views (4 files, lowest risk):**
Extract standalone sub-structs that have no dependencies on `ChatDetailView` private state:
1. `MessageBubble.swift`
2. `MediaBubbleImage.swift`
3. `ChatReactionsUI.swift`
4. `ChatDetailHelpers.swift` (all the leaf helpers and bootstrap types)
5. Type-check gate

**Phase 2 — View composition (4 files, medium risk):**
Extract the large composed pieces of ChatDetailView:
1. `ChatDetailHeaderView.swift`
2. `ChatTranscriptView.swift`
3. `ChatInputBarView.swift`
4. `ChatMessageContextMenu.swift`
5. Type-check gate
6. ChatDetailView.swift should now be ~350 LOC

**Phase 3 — ViewModel extension split (5 files, low risk — extensions are additive):**
1. `ChatDetailViewModel+Messages.swift`
2. `ChatDetailViewModel+Send.swift`
3. `ChatDetailViewModel+Reactions.swift`
4. `ChatDetailViewModel+Realtime.swift`
5. `ChatDetailViewModel+Search.swift`
6. Type-check gate
7. ChatDetailViewModel.swift should now be ~250 LOC

Phases 1–3 each respect the "≤5 files per phase" limit and "complete phase N before phase N+1" rule from CLAUDE.md.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| SwiftUI `@State` ownership changes break view identity | Each extraction preserves `@State` on its original owner; children receive bindings, never own moved state |
| Private helpers referenced across split boundaries | Audit call sites during Phase 0; promote `private` → `fileprivate` or `internal` only where necessary; prefer passing values as parameters |
| `@StateObject` coordinators rebound to child view break lifecycle | All coordinators stay on `ChatDetailView`; children receive them as `@ObservedObject` or plain references |
| Extension file can't see non-public members of the type | Not an issue — extensions in the same module share access |
| Compilation succeeds but UI regresses | Manual smoke test after each phase: open a conversation, send a message, scroll, open attachment picker, send media, search. Any visible regression rolls back the phase. |
| File-layout drift after extraction (dead `import` lines, stale `// MARK:`) | Code-quality review subagent reviews each phase's commits |

## Success Criteria

- `ChatDetailView.swift` ≤ 450 LOC
- `ChatDetailViewModel.swift` ≤ 300 LOC
- 13 new files created, each ≤ 450 LOC
- Zero Swift compilation errors
- All pre-existing tests pass
- Manual smoke test: open chat, send text, send photo, send voice, react, reply, search, archive, delete — all function unchanged
- Each phase commits cleanly and independently bisectable

## Out of Scope (Explicit)

- Any logic change to send pipeline, receive pipeline, crypto, networking
- Any change to `Message`, `MessageSection`, or any model type
- Any UI polish, typography, color, or layout change
- ConversationInfoView refactor (separate future spec)
- ChatsListView refactor (separate future spec)
- New unit tests for the split ViewModel (unblocked by this, tracked separately)
