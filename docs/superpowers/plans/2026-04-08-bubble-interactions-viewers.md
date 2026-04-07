# Bubble Interactions & Rich Media Viewers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every rich-content message bubble (image, video, contact, location, document) tappable, opening a type-appropriate viewer with production-grade features.

**Architecture:** Closure-based tap dispatch — cells fire a `MessageInteraction` up through `MessageCollectionView` into `ChatDetailViewModel`, which routes to one of four `@MainActor ObservableObject` coordinators that drive SwiftUI presentations. All coordinators live as `@StateObject`s inside `ChatDetailView`. Reuses the existing `ChatDetailViewModel.messages` in-memory snapshot for gallery seeding (no DB hit on tap) and the existing `MediaDownloadManager.download` pipeline for decrypted bytes.

**Tech Stack:** SwiftUI + UIKit interop (`UIViewRepresentable` / `UIViewControllerRepresentable`), MapKit (iOS 17+), AVKit (`AVPlayerViewController`), QuickLook (`QLPreviewController`), Photos (`PHPhotoLibrary`), Contacts (`CNContactViewController`), Photos library via `NSPhotoLibraryAddUsageDescription`.

**Spec:** `docs/superpowers/specs/2026-04-08-bubble-interactions-viewers-design.md`

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `SanchrShared/Messaging/MessageInteraction.swift` | Tap-payload enum flowing from cells → VM |
| `Shared/Services/ChatMediaResolver.swift` | Protocol + impl wrapping `MediaDownloadManager`; adds `decryptedURLWithDisplayName` for QuickLook |
| `Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryCoordinator.swift` | Coordinator + `GalleryItem` model |
| `Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift` | SwiftUI pager container + chrome + dismiss gesture |
| `Features/Chats/Presentation/Viewers/MediaGallery/GalleryImageView.swift` | `UIViewRepresentable` zoom+pan `UIScrollView` |
| `Features/Chats/Presentation/Viewers/MediaGallery/GalleryVideoView.swift` | `UIViewControllerRepresentable` AVPlayerVC |
| `Features/Chats/Presentation/Viewers/MediaGallery/SaveToPhotos.swift` | `PHPhotoLibrary.addOnly` write helper |
| `Features/Chats/Presentation/Viewers/Contact/ContactActionCoordinator.swift` | Coordinator + `PendingContact` model + lookup |
| `Features/Chats/Presentation/Viewers/Contact/ContactActionSheet.swift` | SwiftUI `.sheet` UI |
| `Features/Chats/Presentation/Viewers/Contact/ContactViewControllerHost.swift` | `CNContactViewController` wrapper |
| `Features/Chats/Presentation/Viewers/Location/LocationPreviewCoordinator.swift` | Coordinator |
| `Features/Chats/Presentation/Viewers/Location/LocationPreviewView.swift` | `Map` + reverse-geocode + action sheet |
| `Features/Chats/Presentation/Viewers/Document/DocumentPreviewCoordinator.swift` | Coordinator + resolver call |
| `Features/Chats/Presentation/Viewers/Document/DocumentPreviewView.swift` | `QLPreviewController` wrapper |
| `Tests/UnitTests/Features/Chats/Viewers/ChatDetailViewModelRoutingTests.swift` | Tap routing |
| `Tests/UnitTests/Features/Chats/Viewers/MediaGallerySeedingTests.swift` | Gallery seeding from messages |
| `Tests/UnitTests/Features/Chats/Viewers/ContactActionCoordinatorTests.swift` | Resolution + row gating |
| `Tests/UnitTests/Features/Chats/Viewers/ChatMediaResolverTests.swift` | Filename fidelity + cache reuse |

### Modified files

| Path | Change |
|---|---|
| `Features/Chats/Presentation/ChatDetailView.swift` | Add `MessageBubble.onBubbleTap` closure; mount four coordinators; add `.onTapGesture` on sub-views |
| `Features/Chats/Presentation/MessageCollectionView.swift` | Add `onBubbleTap` property, wire through |
| `Features/Chats/Presentation/MessageCollectionViewController.swift` | Add `onBubbleTap` property, pass into `MessageBubble` in cell registration |
| `Features/Chats/Presentation/ChatDetailViewModel.swift` | Add `route(interaction:)` + `galleryItems(for:)` |
| `Shared/Repositories/MessageRepository.swift` | Add `startDirectConversation(peerUserId:)` wrapping the generated RPC |
| `App/DependencyContainer.swift` | Expose `chatMediaResolver` |
| `project.yml` | `NSPhotoLibraryAddUsageDescription` + `LSApplicationQueriesSchemes[comgooglemaps]` |
| `Tests/UnitTests/TestDoubles.swift` | Add `MockChatMediaResolver`, extend `MockContactRepository` |

---

## Task Breakdown

Tasks are grouped into seven phases. Each phase ends with a build + commit gate, matching the project's "≤5 files per phase" directive in `CLAUDE.md`. Every code step lists the exact file and the exact code. Verification for every phase is `xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build` — must end with `** BUILD SUCCEEDED **`.

---

## Phase 1 — Tap dispatch spine

Goal: a tap on any rich bubble fires a `MessageInteraction` up into `ChatDetailViewModel.route(interaction:)` which logs and returns. No viewers wired yet. This phase MUST leave the app building and behaving identically to before.

### Task 1: `MessageInteraction` enum in SanchrShared

**Files:**
- Create: `ios/Sanchr-iOS/SanchrShared/Messaging/MessageInteraction.swift`

- [ ] **Step 1: Create the file with the full enum**

```swift
import Foundation

/// Tap payload flowing from a rendered `MessageBubble` up through the
/// collection view representable into `ChatDetailViewModel`.
///
/// One enum, one routing switch. Cells never present UI themselves — they
/// fire the interaction and the view model owns the decision of which
/// viewer coordinator to invoke.
public enum MessageInteraction: Sendable, Equatable {
    /// Fired for `.image` and `.video` bubbles. The gallery disambiguates
    /// image vs. video at page-build time so the cell doesn't have to know.
    case openMedia(messageId: String)

    /// Fired for `.contact` bubbles.
    case openContact(name: String, phoneNumber: String)

    /// Fired for `.location` bubbles.
    case openLocation(latitude: Double, longitude: Double)

    /// Fired for `.document` bubbles.
    case openDocument(messageId: String)
}
```

- [ ] **Step 2: Add the file to the Xcode project**

Sanchr uses xcodegen. Regenerate the project with `xcodegen generate` from `ios/Sanchr-iOS/` — the file is under `SanchrShared/` which is already a recursive source path in `project.yml:78`.

- [ ] **Step 3: Build and confirm the new type is visible from main app**

```bash
cd ios/Sanchr-iOS && xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add SanchrShared/Messaging/MessageInteraction.swift
git commit -m "feat(shared): add MessageInteraction tap payload enum"
```

---

### Task 2: Thread the `onBubbleTap` closure through the collection view layer

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/MessageCollectionView.swift:22-97`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/MessageCollectionViewController.swift`

- [ ] **Step 1: Add the closure property on the view controller**

Open `Features/Chats/Presentation/MessageCollectionViewController.swift` and find the block of existing callback properties (around the other `onReplyToMessage`, `onReactToMessage` declarations near the top of the class). Add:

```swift
/// Forwarded from `MessageBubble.onBubbleTap`. The view model owns the
/// routing decision; this controller just plumbs the payload upward.
var onBubbleTap: ((MessageInteraction) -> Void)?
```

- [ ] **Step 2: Add the closure property on the representable and wire it in both `makeUIViewController` and `updateUIViewController`**

In `Features/Chats/Presentation/MessageCollectionView.swift` add the property after `let onLoadMore`:

```swift
    let onBubbleTap: (MessageInteraction) -> Void
```

In `makeUIViewController`, after the existing `vc.onLoadMore = { onLoadMore() }`, add:

```swift
        vc.onBubbleTap = { interaction in
            onBubbleTap(interaction)
        }
```

In `updateUIViewController`, mirror the same assignment in the same position — `updateUIViewController` already re-wires every other callback so updated SwiftUI closures are honored.

- [ ] **Step 3: Update the single call site of `MessageCollectionView(...)` in `ChatDetailView`**

`ChatDetailView.swift` has exactly one `MessageCollectionView(` constructor call (grep for it). Add `onBubbleTap: { _ in }` at the end of the argument list — temporary no-op until Phase 1 Task 4 wires routing. Do this in the same position relative to the other callbacks; don't reorder.

- [ ] **Step 4: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. There are no behavior changes yet — we just plumbed an empty closure.

- [ ] **Step 5: Commit**

```bash
git add Features/Chats/Presentation/MessageCollectionView.swift \
        Features/Chats/Presentation/MessageCollectionViewController.swift \
        Features/Chats/Presentation/ChatDetailView.swift
git commit -m "feat(chats): plumb onBubbleTap closure through transcript representable"
```

---

### Task 3: Wire tap gestures into `MessageBubble`

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift:1122-1211` (MessageBubble struct) and `messageContent` switch case body

- [ ] **Step 1: Add the `onBubbleTap` property to `MessageBubble`**

Locate `struct MessageBubble: View {` at `ChatDetailView.swift:1122`. Add the property at the bottom of the declarations block, after `voicePlayback: VoicePlaybackController`:

```swift
    var onBubbleTap: (MessageInteraction) -> Void = { _ in }
```

- [ ] **Step 2: Attach tap handlers in the `messageContent` switch cases**

Find the `@ViewBuilder private var messageContent` switch at `ChatDetailView.swift:1225`. For each of the five content cases, apply `.contentShape(Rectangle())` before `.onTapGesture` so the transparent padding is still tappable, then fire the appropriate interaction. The exact edits:

For `case .image(let attachment):` — after the last modifier on the image sub-view that wraps the thumbnail, add:

```swift
            .contentShape(Rectangle())
            .onTapGesture {
                onBubbleTap(.openMedia(messageId: message.id))
            }
```

For `case .video(let attachment):` — identical pattern, same interaction:

```swift
            .contentShape(Rectangle())
            .onTapGesture {
                onBubbleTap(.openMedia(messageId: message.id))
            }
```

For `case .document(let attachment):` — same pattern, different interaction:

```swift
            .contentShape(Rectangle())
            .onTapGesture {
                onBubbleTap(.openDocument(messageId: message.id))
            }
```

For `case .location(let latitude, let longitude):` — same pattern:

```swift
            .contentShape(Rectangle())
            .onTapGesture {
                onBubbleTap(.openLocation(latitude: latitude, longitude: longitude))
            }
```

For `case .contact(let name, let phoneNumber):` — same pattern:

```swift
            .contentShape(Rectangle())
            .onTapGesture {
                onBubbleTap(.openContact(name: name, phoneNumber: phoneNumber))
            }
```

**IMPORTANT:** if the same file has `AttachmentFallbackParser.parse(text)` rendering `contactFallbackBubble` / `locationFallbackBubble` from a text message (at `ChatDetailView.swift:1228-1234`), apply the same tap handlers there too — fallback-parsed bubbles render identical content and must behave identically when tapped. Use the same interaction payloads (`.openContact` / `.openLocation`) with the parsed values.

- [ ] **Step 3: Pass `onBubbleTap` into `MessageBubble` at the cell registration site**

Find the `MessageBubble(` constructor call at `MessageCollectionViewController.swift:333`. After the last existing argument (`voicePlayback: self?.voicePlayback ?? VoicePlaybackController()`), add:

```swift
                        onBubbleTap: { [weak self] interaction in
                            self?.onBubbleTap?(interaction)
                        }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. The tap fires but lands in the empty closure from Task 2 Step 3, so the app still behaves identically.

- [ ] **Step 5: Commit**

```bash
git add Features/Chats/Presentation/ChatDetailView.swift \
        Features/Chats/Presentation/MessageCollectionViewController.swift
git commit -m "feat(chats): fire MessageInteraction on rich-bubble taps"
```

---

### Task 4: `ChatDetailViewModel.route(interaction:)` with a logging-only stub

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailViewModel.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift` (Task 2 Step 3 no-op → real call)
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/Viewers/ChatDetailViewModelRoutingTests.swift`

- [ ] **Step 1: Write a failing test for the router**

Create `Tests/UnitTests/Features/Chats/Viewers/ChatDetailViewModelRoutingTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatDetailViewModelRoutingTests: XCTestCase {

    func test_route_openMedia_recordsLastInteraction() {
        let vm = ChatDetailViewModel()
        vm.route(interaction: .openMedia(messageId: "msg-1"))
        XCTAssertEqual(vm.lastRoutedInteraction, .openMedia(messageId: "msg-1"))
    }

    func test_route_openContact_recordsLastInteraction() {
        let vm = ChatDetailViewModel()
        vm.route(interaction: .openContact(name: "Alice", phoneNumber: "+15551234"))
        XCTAssertEqual(vm.lastRoutedInteraction,
                       .openContact(name: "Alice", phoneNumber: "+15551234"))
    }

    func test_route_openLocation_recordsLastInteraction() {
        let vm = ChatDetailViewModel()
        vm.route(interaction: .openLocation(latitude: 12.9716, longitude: 77.5946))
        XCTAssertEqual(vm.lastRoutedInteraction,
                       .openLocation(latitude: 12.9716, longitude: 77.5946))
    }

    func test_route_openDocument_recordsLastInteraction() {
        let vm = ChatDetailViewModel()
        vm.route(interaction: .openDocument(messageId: "doc-1"))
        XCTAssertEqual(vm.lastRoutedInteraction, .openDocument(messageId: "doc-1"))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails to compile (expected)**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | grep -E "error:" | head
```
Expected: errors like `value of type 'ChatDetailViewModel' has no member 'route'` and `'lastRoutedInteraction'`.

- [ ] **Step 3: Add `lastRoutedInteraction` and `route(interaction:)` on the view model**

In `ChatDetailViewModel.swift`, inside `final class ChatDetailViewModel`, add the property near the top of the declarations:

```swift
    /// Most recent interaction routed through `route(interaction:)`. Visible
    /// to tests only — the real app reads the coordinators, not this. Left
    /// here because it's the cheapest way to unit-test routing without
    /// coupling the test to the coordinator implementations.
    var lastRoutedInteraction: MessageInteraction?
```

And add the method (placement: near the other public entry-point methods such as `send(...)`):

```swift
    /// Dispatch a bubble-tap interaction to the appropriate coordinator.
    /// Phase 1 stub — just records and logs. Later phases attach real
    /// coordinator invocations.
    func route(interaction: MessageInteraction) {
        lastRoutedInteraction = interaction
        SanchrLogger.chat.info("ChatDetailViewModel routing interaction: \(String(describing: interaction))")
    }
```

- [ ] **Step 4: Replace the Phase 1 Task 2 empty-closure placeholder with a real call**

Locate the `MessageCollectionView(` call in `ChatDetailView.swift`. Change the `onBubbleTap: { _ in }` stub to:

```swift
                onBubbleTap: { interaction in
                    viewModel.route(interaction: interaction)
                }
```

- [ ] **Step 5: Run the test and confirm it passes**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:SanchrTests/ChatDetailViewModelRoutingTests 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`. If x86_64 simulator linker blocks tests the same way it blocks the main app build (see previous work), target `arm64` by running on an `iPhone 15 Pro` simulator that is ARM-native on Apple Silicon Macs.

- [ ] **Step 6: Build the full app**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Features/Chats/Presentation/ChatDetailViewModel.swift \
        Features/Chats/Presentation/ChatDetailView.swift \
        Tests/UnitTests/Features/Chats/Viewers/ChatDetailViewModelRoutingTests.swift
git commit -m "feat(chats): route bubble-tap interactions through ChatDetailViewModel"
```

**End of Phase 1** — taps now flow from every rich bubble into `ChatDetailViewModel.route(interaction:)`. Nothing visible yet.

---

## Phase 2 — Media gallery (image + video pager)

Goal: tapping an image or video bubble opens a fullscreen gallery that pages across all chat media, with working pinch-zoom/pan/double-tap on images and native AVPlayerVC chrome on videos. Swipe-down-to-dismiss. No save/share actions yet — that's Phase 3.

### Task 5: `ChatMediaResolver` seam over `MediaDownloadManager`

**Files:**
- Create: `ios/Sanchr-iOS/Shared/Services/ChatMediaResolver.swift`
- Modify: `ios/Sanchr-iOS/App/DependencyContainer.swift` (expose the resolver)
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/TestDoubles.swift` (add mock)
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/Viewers/ChatMediaResolverTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/UnitTests/Features/Chats/Viewers/ChatMediaResolverTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

final class ChatMediaResolverTests: XCTestCase {

    func test_decryptedURL_returnsDownloadedFileURL() async throws {
        let cached = makeCacheFile(name: "msg-1.jpg", bytes: Data([0xAA]))
        let download = FakeMediaDownload(nextReturn: cached)
        let resolver = ChatMediaResolverImpl(download: download)
        let attachment = Self.makeImageAttachment()

        let url = try await resolver.decryptedURL(
            forMessageId: "msg-1",
            attachment: attachment
        )

        XCTAssertEqual(url, cached)
        XCTAssertEqual(download.calls, [.init(messageId: "msg-1")])
    }

    func test_decryptedURLWithDisplayName_linksUnderOriginalFilename() async throws {
        let cached = makeCacheFile(name: "msg-7.bin", bytes: Data([0x01, 0x02]))
        let download = FakeMediaDownload(nextReturn: cached)
        let resolver = ChatMediaResolverImpl(download: download)
        let attachment = Self.makeDocumentAttachment(filename: "Invoice Q4.pdf")

        let url = try await resolver.decryptedURLWithDisplayName(
            forMessageId: "msg-7",
            attachment: attachment
        )

        XCTAssertEqual(url.lastPathComponent, "Invoice Q4.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_decryptedURLWithDisplayName_fallsBackToMessageIdWhenFilenameMissing() async throws {
        let cached = makeCacheFile(name: "msg-9.bin", bytes: Data([0x0F]))
        let download = FakeMediaDownload(nextReturn: cached)
        let resolver = ChatMediaResolverImpl(download: download)
        let attachment = Self.makeDocumentAttachment(filename: nil)

        let url = try await resolver.decryptedURLWithDisplayName(
            forMessageId: "msg-9",
            attachment: attachment
        )

        XCTAssertEqual(url.lastPathComponent, "msg-9.bin")
    }

    // MARK: - Helpers

    private func makeCacheFile(name: String, bytes: Data) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try! bytes.write(to: url)
        return url
    }

    private static func makeImageAttachment() -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://abc")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "image/jpeg",
            sizeBytes: 100
        )
    }

    private static func makeDocumentAttachment(filename: String?) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://xyz")!,
            encryptionKey: Data([0x01]),
            encryptionIV: Data([0x02]),
            mimeType: "application/pdf",
            sizeBytes: 100,
            filename: filename
        )
    }
}

private final class FakeMediaDownload: MediaDownloading, @unchecked Sendable {
    struct Call: Equatable { let messageId: String }
    var calls: [Call] = []
    var nextReturn: URL
    init(nextReturn: URL) { self.nextReturn = nextReturn }
    func download(messageId: String, attachment: Message.MediaAttachment) async throws -> URL {
        calls.append(Call(messageId: messageId))
        return nextReturn
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails to compile**

Expected errors: `ChatMediaResolverImpl`, `MediaDownloading` not found.

- [ ] **Step 3: Create `ChatMediaResolver.swift`**

```swift
import Foundation
import SanchrShared

/// Seam around the existing `MediaDownloadManager` so viewer code can be
/// unit-tested without a gRPC client, and so the document path can add a
/// filename-preserving copy for `QLPreviewController` without mutating the
/// shared download cache.
///
/// The underlying `MediaDownloadManager.download` returns a file under
/// `<cache>/<messageId>.<ext>`. That URL is fine for the gallery (images +
/// video AVAsset loading) but QuickLook shows the last path component as
/// the display title, so PDFs would render as `msg-7.pdf` instead of
/// `Invoice Q4.pdf`. `decryptedURLWithDisplayName` fixes this by hard-
/// linking the cached file into a per-message display directory under its
/// original filename. Hard link not copy — zero extra bytes on disk, and
/// link creation is atomic.
protocol ChatMediaResolving: Sendable {
    /// Returns the decrypted local file URL for an image / video. Honors
    /// the shared `MediaDownloadManager` cache and in-flight coalescing.
    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL

    /// Returns a local file URL whose last path component is the original
    /// attachment filename (if present). Used by the document viewer so
    /// `QLPreviewController` surfaces the user-facing title.
    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL
}

/// Thin protocol matching the subset of `MediaDownloadManager` we use.
/// Extracted so tests can inject fakes without touching gRPC / Keychain.
protocol MediaDownloading: Sendable {
    func download(
        messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL
}

extension MediaDownloadManager: MediaDownloading {}

final class ChatMediaResolverImpl: ChatMediaResolving, @unchecked Sendable {
    private let download: MediaDownloading
    private let displayLinkRoot: URL

    init(
        download: MediaDownloading,
        displayLinkRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanchr-quicklook", isDirectory: true)
    ) {
        self.download = download
        self.displayLinkRoot = displayLinkRoot
        try? FileManager.default.createDirectory(
            at: displayLinkRoot,
            withIntermediateDirectories: true
        )
    }

    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        try await download.download(messageId: messageId, attachment: attachment)
    }

    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        let cached = try await download.download(
            messageId: messageId,
            attachment: attachment
        )
        guard let displayName = attachment.filename, !displayName.isEmpty else {
            return cached
        }
        let perMessageDir = displayLinkRoot.appendingPathComponent(messageId, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: perMessageDir,
            withIntermediateDirectories: true
        )
        let linked = perMessageDir.appendingPathComponent(displayName)
        if FileManager.default.fileExists(atPath: linked.path) {
            return linked
        }
        try FileManager.default.linkItem(at: cached, to: linked)
        return linked
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:SanchrTests/ChatMediaResolverTests 2>&1 | tail -5
```
Expected: all three tests pass.

- [ ] **Step 5: Expose on `DependencyContainer`**

In `App/DependencyContainer.swift`, find where `MediaDownloadManager` is constructed (grep for `MediaDownloadManager`). Add a sibling property:

```swift
    private(set) lazy var chatMediaResolver: ChatMediaResolving = ChatMediaResolverImpl(
        download: mediaDownloadManager
    )
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Shared/Services/ChatMediaResolver.swift \
        App/DependencyContainer.swift \
        Tests/UnitTests/Features/Chats/Viewers/ChatMediaResolverTests.swift
git commit -m "feat(chats): add ChatMediaResolver seam with filename-preserving hard link"
```

---

### Task 6: Gallery seeding on `ChatDetailViewModel`

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailViewModel.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/Viewers/MediaGallerySeedingTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/UnitTests/Features/Chats/Viewers/MediaGallerySeedingTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class MediaGallerySeedingTests: XCTestCase {

    func test_galleryItemsForTap_returnsOnlyMediaInChronologicalOrder() throws {
        let vm = ChatDetailViewModel()
        vm.messages = [
            Self.text(id: "t1", sent: 100),
            Self.image(id: "i1", sent: 200),
            Self.text(id: "t2", sent: 300),
            Self.video(id: "v1", sent: 400),
            Self.image(id: "i2", sent: 500),
        ]

        let seed = try XCTUnwrap(vm.galleryItems(forTappedMessageId: "v1"))

        XCTAssertEqual(seed.items.map(\.id), ["i1", "v1", "i2"])
        XCTAssertEqual(seed.items.map(\.kind), [.image, .video, .image])
        XCTAssertEqual(seed.initialIndex, 1)
    }

    func test_galleryItemsForTap_returnsNilWhenMessageIsNotMedia() {
        let vm = ChatDetailViewModel()
        vm.messages = [Self.text(id: "t1", sent: 100)]
        XCTAssertNil(vm.galleryItems(forTappedMessageId: "t1"))
    }

    func test_galleryItemsForTap_returnsNilWhenMessageIdMissing() {
        let vm = ChatDetailViewModel()
        vm.messages = [Self.image(id: "i1", sent: 100)]
        XCTAssertNil(vm.galleryItems(forTappedMessageId: "unknown"))
    }

    // MARK: - Builders

    private static func text(id: String, sent: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: sent),
            content: .text("hello"),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func image(id: String, sent: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: sent),
            content: .image(Self.attachment(mime: "image/jpeg")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func video(id: String, sent: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: sent),
            content: .video(Self.attachment(mime: "video/mp4")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func attachment(mime: String) -> Message.MediaAttachment {
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

- [ ] **Step 2: Add the seeding method on `ChatDetailViewModel`**

In `ChatDetailViewModel.swift` add the method near `route(interaction:)`:

```swift
    /// Seed the media gallery coordinator with every image + video in the
    /// current in-memory chat snapshot, ordered chronologically, with the
    /// tapped message's index. Returns `nil` if the tapped message isn't
    /// media or isn't in the current snapshot.
    ///
    /// The snapshot is frozen at call time — new messages arriving while
    /// the gallery is open do NOT mutate the pager (would shift pages
    /// under the user's finger).
    func galleryItems(forTappedMessageId messageId: String) -> GallerySeed? {
        let ordered = messages
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { msg -> GalleryItem? in
                switch msg.content {
                case .image:
                    return GalleryItem(
                        id: msg.id,
                        kind: .image,
                        message: msg
                    )
                case .video:
                    return GalleryItem(
                        id: msg.id,
                        kind: .video,
                        message: msg
                    )
                default:
                    return nil
                }
            }
        guard let index = ordered.firstIndex(where: { $0.id == messageId }) else {
            return nil
        }
        return GallerySeed(items: ordered, initialIndex: index)
    }
}

// MARK: - Gallery DTOs

struct GallerySeed: Equatable {
    let items: [GalleryItem]
    let initialIndex: Int
}

struct GalleryItem: Identifiable, Equatable {
    enum Kind: Equatable { case image, video }
    let id: String                    // messageId
    let kind: Kind
    let message: Message
}
```

Note: the closing `}` of `GalleryItem` is the last line of the new block. `ChatDetailViewModel` is already an `@Observable` class — the extension types sit at file scope.

- [ ] **Step 3: Run the tests, confirm pass**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:SanchrTests/MediaGallerySeedingTests 2>&1 | tail -5
```
Expected: all three pass.

- [ ] **Step 4: Commit**

```bash
git add Features/Chats/Presentation/ChatDetailViewModel.swift \
        Tests/UnitTests/Features/Chats/Viewers/MediaGallerySeedingTests.swift
git commit -m "feat(chats): seed gallery pager from in-memory message snapshot"
```

---

### Task 7: `MediaGalleryCoordinator`

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryCoordinator.swift`

- [ ] **Step 1: Create the coordinator file**

```swift
import SwiftUI
import SanchrShared

@MainActor
final class MediaGalleryCoordinator: ObservableObject {
    @Published var presentation: GalleryPresentation?

    struct GalleryPresentation: Identifiable, Equatable {
        let id = UUID()
        let items: [GalleryItem]
        let initialIndex: Int
    }

    func present(seed: GallerySeed) {
        presentation = GalleryPresentation(
            items: seed.items,
            initialIndex: seed.initialIndex
        )
    }

    func dismiss() {
        presentation = nil
    }
}
```

- [ ] **Step 2: Wire routing in `ChatDetailViewModel.route`**

`ChatDetailViewModel` cannot own a `@MainActor ObservableObject` reference directly without making itself one — but since `ChatDetailViewModel` is `@Observable` (not `ObservableObject`) and `@MainActor`-implicit-via-SwiftUI-use, the cleanest path is to let the coordinator live in the SwiftUI view and forward the routing through a callback. Update `route(interaction:)` signature **now** to accept an `onOpenGallery: (GallerySeed) -> Void` handler the view provides:

Replace the existing `route(interaction:)` body with:

```swift
    /// Routing entry point. The view (`ChatDetailView`) provides the
    /// per-interaction presentation handlers as closures because the
    /// coordinators themselves are `@StateObject`s and must live in the
    /// view hierarchy. The VM stays `@Observable` without having to hold
    /// references to `ObservableObject`s.
    func route(
        interaction: MessageInteraction,
        onOpenGallery: (GallerySeed) -> Void = { _ in },
        onOpenContact: (String, String) -> Void = { _, _ in },
        onOpenLocation: (Double, Double) -> Void = { _, _ in },
        onOpenDocument: (String) -> Void = { _ in }
    ) {
        lastRoutedInteraction = interaction
        switch interaction {
        case .openMedia(let messageId):
            guard let seed = galleryItems(forTappedMessageId: messageId) else {
                SanchrLogger.chat.warning("route: no gallery seed for \(messageId.prefix(8))")
                return
            }
            onOpenGallery(seed)
        case .openContact(let name, let phoneNumber):
            onOpenContact(name, phoneNumber)
        case .openLocation(let latitude, let longitude):
            onOpenLocation(latitude, longitude)
        case .openDocument(let messageId):
            onOpenDocument(messageId)
        }
    }
```

This keeps `ChatDetailViewModelRoutingTests` from Task 4 green because it still calls the zero-arg-default variant. All four tests still pass.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryCoordinator.swift \
        Features/Chats/Presentation/ChatDetailViewModel.swift
git commit -m "feat(chats): add MediaGalleryCoordinator and viewmodel routing hooks"
```

---

### Task 8: `GalleryImageView` (zoom + pan scroll view)

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/MediaGallery/GalleryImageView.swift`

- [ ] **Step 1: Create the `UIViewRepresentable`**

```swift
import SwiftUI
import UIKit

/// Zoom + pan + double-tap-to-zoom image page. A `UIScrollView` wraps a
/// `UIImageView`; the SwiftUI-side binding lets us swap the image in
/// asynchronously as the decrypted file lands.
///
/// SwiftUI's `ScrollView` can't deliver all three behaviors simultaneously
/// (pinch + pan centered when zoomed below fill + double-tap zoom point)
/// without dropping frames, so we hand-build the recipe in UIKit.
struct GalleryImageView: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView()
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.setImage(image)
    }
}

/// Standalone UIKit view so we can unit-test layout + zoom math
/// independently of SwiftUI wiring.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        delegate = self

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if imageView.image != nil {
            imageView.frame = bounds
            centerImage()
        }
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    /// Recenter the image when zoomed out below fill so it doesn't stick
    /// to the top-left corner.
    private func centerImage() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame
        frameToCenter.origin.x = frameToCenter.width < boundsSize.width
            ? (boundsSize.width - frameToCenter.width) / 2
            : 0
        frameToCenter.origin.y = frameToCenter.height < boundsSize.height
            ? (boundsSize.height - frameToCenter.height) / 2
            : 0
        imageView.frame = frameToCenter
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = gr.location(in: imageView)
            let targetScale: CGFloat = 3
            let rect = zoomRect(forScale: targetScale, center: point)
            zoom(to: rect, animated: true)
        }
    }

    private func zoomRect(forScale scale: CGFloat, center: CGPoint) -> CGRect {
        let size = CGSize(
            width: bounds.width / scale,
            height: bounds.height / scale
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Features/Chats/Presentation/Viewers/MediaGallery/GalleryImageView.swift
git commit -m "feat(chats): add ZoomableImageScrollView for gallery image pages"
```

---

### Task 9: `GalleryVideoView` (AVPlayerVC wrapper)

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/MediaGallery/GalleryVideoView.swift`

- [ ] **Step 1: Create the representable**

```swift
import SwiftUI
import AVKit

/// `AVPlayerViewController` wrapper. Gives the gallery native scrub bar,
/// skip-15s, AirPlay, PiP, speed, and subtitle support for free.
///
/// The player is created lazily inside the coordinator's init on first
/// update and torn down when the page disappears — swiping away stops
/// playback. PiP is the only state that survives dismissal; that's
/// handled by AVFoundation itself, nothing to wire here.
struct GalleryVideoView: UIViewControllerRepresentable {
    let url: URL
    @Binding var isActive: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        vc.modalPresentationStyle = .overFullScreen
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if !isActive {
            vc.player?.pause()
        }
    }

    static func dismantleUIViewController(
        _ vc: AVPlayerViewController,
        coordinator: ()
    ) {
        vc.player?.pause()
        vc.player = nil
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Features/Chats/Presentation/Viewers/MediaGallery/GalleryVideoView.swift
git commit -m "feat(chats): add AVPlayerViewController wrapper for gallery video pages"
```

---

### Task 10: `MediaGalleryView` container with pager + dismiss gesture

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Create the container view**

```swift
import SwiftUI
import SanchrShared

struct MediaGalleryView: View {
    let presentation: MediaGalleryCoordinator.GalleryPresentation
    let resolver: ChatMediaResolving
    let onDismiss: () -> Void

    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0
    @State private var backgroundOpacity: Double = 1
    @State private var resolvedURLs: [String: URL] = [:]
    @State private var loadError: [String: String] = [:]
    @State private var chromeVisible: Bool = true

    init(
        presentation: MediaGalleryCoordinator.GalleryPresentation,
        resolver: ChatMediaResolving,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.resolver = resolver
        self.onDismiss = onDismiss
        self._currentIndex = State(initialValue: presentation.initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(presentation.items.enumerated()), id: \.offset) { index, item in
                    pageContent(item: item, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .highPriorityGesture(dismissDrag)

            if chromeVisible {
                chromeOverlay
            }
        }
        .statusBarHidden(true)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
        .task(id: currentIndex) {
            await resolveIfNeeded(at: currentIndex)
            // Prefetch neighbors for smoother paging
            await resolveIfNeeded(at: currentIndex + 1)
            await resolveIfNeeded(at: currentIndex - 1)
        }
    }

    @ViewBuilder
    private func pageContent(item: GalleryItem, index: Int) -> some View {
        switch item.kind {
        case .image:
            GalleryImageView(image: resolvedImage(for: item))
                .ignoresSafeArea()
        case .video:
            if let url = resolvedURLs[item.id] {
                GalleryVideoView(
                    url: url,
                    isActive: .constant(index == currentIndex)
                )
                .ignoresSafeArea()
            } else if let error = loadError[item.id] {
                retryView(error: error, messageId: item.id)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var chromeOverlay: some View {
        VStack {
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Circle())
                }
                .padding(.leading, 16)

                Spacer()

                if presentation.items.indices.contains(currentIndex) {
                    let msg = presentation.items[currentIndex].message
                    Text(Self.titleText(for: msg))
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()

                // Overflow slot — populated in Phase 3.
                Color.clear.frame(width: 36, height: 36).padding(.trailing, 16)
            }
            .padding(.top, 50)

            Spacer()
        }
    }

    @ViewBuilder
    private func retryView(error: String, messageId: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.yellow)
            Text(error)
                .font(.footnote)
                .foregroundColor(.white)
            Button("Retry") {
                loadError[messageId] = nil
                Task { await resolveIfNeeded(at: currentIndex) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Dismiss drag

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragOffset = value.translation.height
                backgroundOpacity = max(0, 1 - Double(value.translation.height / 400))
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 1000
                        backgroundOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                    }
                } else {
                    withAnimation(.spring()) {
                        dragOffset = 0
                        backgroundOpacity = 1
                    }
                }
            }
    }

    // MARK: - Resolution

    @MainActor
    private func resolveIfNeeded(at index: Int) async {
        guard presentation.items.indices.contains(index) else { return }
        let item = presentation.items[index]
        guard resolvedURLs[item.id] == nil, loadError[item.id] == nil else { return }
        guard let attachment = Self.attachment(for: item.message) else { return }
        do {
            let url = try await resolver.decryptedURL(
                forMessageId: item.id,
                attachment: attachment
            )
            resolvedURLs[item.id] = url
        } catch {
            loadError[item.id] = error.localizedDescription
        }
    }

    private func resolvedImage(for item: GalleryItem) -> UIImage? {
        guard let url = resolvedURLs[item.id] else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func attachment(for message: Message) -> Message.MediaAttachment? {
        switch message.content {
        case .image(let a), .video(let a): return a
        default: return nil
        }
    }

    private static func titleText(for message: Message) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: message.timestamp, relativeTo: Date())
    }
}
```

- [ ] **Step 2: Mount the gallery coordinator + presentation in `ChatDetailView`**

Open `ChatDetailView.swift`. Near the top of the struct (after the existing `@State` vars around line 13-29) add:

```swift
    @StateObject private var galleryCoordinator = MediaGalleryCoordinator()
```

Find the `MessageCollectionView(` call modified in Task 2/4. Replace the `onBubbleTap` closure body with:

```swift
                onBubbleTap: { interaction in
                    viewModel.route(
                        interaction: interaction,
                        onOpenGallery: { seed in
                            galleryCoordinator.present(seed: seed)
                        }
                    )
                }
```

At the bottom of the `var body: some View { ... }` outer `VStack`, apply a `.fullScreenCover` bound to the coordinator's presentation:

```swift
        .fullScreenCover(item: $galleryCoordinator.presentation) { presentation in
            MediaGalleryView(
                presentation: presentation,
                resolver: container.chatMediaResolver,
                onDismiss: { galleryCoordinator.dismiss() }
            )
        }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual smoke**

Run on a device or arm64 simulator. Send an image in a chat, tap it — the gallery should open, pinch-zoom should work, swipe should page to adjacent images/videos, swipe down should dismiss, the close X should dismiss. No save/share yet.

- [ ] **Step 5: Commit**

```bash
git add Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift \
        Features/Chats/Presentation/ChatDetailView.swift
git commit -m "feat(chats): ship MediaGalleryView pager with zoom/pan/video"
```

**End of Phase 2** — image and video bubbles now open a fully interactive gallery.

---

## Phase 3 — Gallery save / share / delete stub polish

Goal: add the overflow `⋯` menu with Save to Photos, Share, Copy. Also add the `NSPhotoLibraryAddUsageDescription` Info.plist key via `project.yml`. Separate phase so Phase 2 stays ≤5 files.

### Task 11: Info.plist additions via `project.yml`

**Files:**
- Modify: `ios/Sanchr-iOS/project.yml`

- [ ] **Step 1: Add the two keys**

Open `project.yml`. Locate `targets.Sanchr.info.properties` (around line 231). Add:

```yaml
        NSPhotoLibraryAddUsageDescription: "Sanchr saves photos and videos from chats to your library when you tap Save."
        LSApplicationQueriesSchemes:
          - comgooglemaps
```

- [ ] **Step 2: Regenerate**

```bash
cd ios/Sanchr-iOS && xcodegen generate
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add project.yml Sanchr.xcodeproj
git commit -m "chore(ios): add NSPhotoLibraryAddUsageDescription + google maps scheme"
```

---

### Task 12: `SaveToPhotos` helper

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/MediaGallery/SaveToPhotos.swift`

- [ ] **Step 1: Create the helper**

```swift
import Foundation
import Photos

/// Writes a decrypted media file to the system Photos library using
/// `.addOnly` access — we never need to read the library, only add.
/// Errors propagate to the caller so the gallery can show an alert.
enum SaveToPhotos {
    enum SaveError: LocalizedError {
        case permissionDenied
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Sanchr doesn't have permission to add items to your Photos library. Open Settings to enable it."
            case .writeFailed(let message):
                return "Couldn't save to Photos: \(message)"
            }
        }
    }

    enum MediaKind {
        case image
        case video
    }

    static func save(
        fileURL: URL,
        kind: MediaKind
    ) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        default:
            throw SaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                switch kind {
                case .image:
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                case .video:
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                }
            }, completionHandler: { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: SaveError.writeFailed(error?.localizedDescription ?? "unknown"))
                }
            })
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Features/Chats/Presentation/Viewers/MediaGallery/SaveToPhotos.swift
git commit -m "feat(chats): add SaveToPhotos helper for gallery overflow menu"
```

---

### Task 13: Gallery overflow menu (Save / Share / Copy)

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift`

- [ ] **Step 1: Add state for toast + alert**

Add near the other `@State` properties in `MediaGalleryView`:

```swift
    @State private var toast: String?
    @State private var saveError: String?
    @State private var shareURL: URL?
```

- [ ] **Step 2: Replace the overflow slot with a real `Menu`**

Replace the `Color.clear.frame(width: 36, height: 36)` line in `chromeOverlay` with:

```swift
                Menu {
                    Button {
                        Task { await saveCurrentToPhotos() }
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        shareCurrent()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        copyCurrent()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Circle())
                }
                .padding(.trailing, 16)
```

- [ ] **Step 3: Add the action methods**

Add inside `MediaGalleryView`:

```swift
    private func currentItem() -> GalleryItem? {
        guard presentation.items.indices.contains(currentIndex) else { return nil }
        return presentation.items[currentIndex]
    }

    private func saveCurrentToPhotos() async {
        guard let item = currentItem(), let url = resolvedURLs[item.id] else {
            saveError = "The file isn't ready yet — try again in a moment."
            return
        }
        do {
            try await SaveToPhotos.save(
                fileURL: url,
                kind: item.kind == .video ? .video : .image
            )
            toast = item.kind == .video ? "Video saved to Photos" : "Image saved to Photos"
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func shareCurrent() {
        guard let item = currentItem(), let url = resolvedURLs[item.id] else { return }
        shareURL = url
    }

    private func copyCurrent() {
        guard let item = currentItem(), let url = resolvedURLs[item.id] else { return }
        if item.kind == .image, let image = UIImage(contentsOfFile: url.path) {
            UIPasteboard.general.image = image
            toast = "Image copied"
        } else {
            UIPasteboard.general.url = url
            toast = "Link copied"
        }
    }
```

- [ ] **Step 4: Attach alert + toast + share sheet modifiers at the end of the outer `ZStack`**

After the `.task(id: currentIndex)` block on the `ZStack`, chain:

```swift
        .alert("Couldn't save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .sheet(item: Binding(
            get: { shareURL.map(IdentifiedURL.init(url:)) },
            set: { if $0 == nil { shareURL = nil } }
        )) { identified in
            ActivityView(items: [identified.url])
        }
```

Add these two tiny helpers at file scope (same file):

```swift
private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Manual smoke**

Open an image, tap `⋯ → Save to Photos`. Expect a permission prompt on first run, then toast "Image saved to Photos". Check the Photos app — the image should be there. Repeat for Share (system share sheet appears) and Copy (pasting in Messages pastes the image).

- [ ] **Step 7: Commit**

```bash
git add Features/Chats/Presentation/Viewers/MediaGallery/MediaGalleryView.swift
git commit -m "feat(chats): add Save/Share/Copy overflow menu to media gallery"
```

**End of Phase 3** — the gallery is feature-complete.

---

## Phase 4 — Contact viewer

Goal: tapping a contact bubble opens a sheet that resolves the phone against Sanchr contacts and device contacts, shows the correct action rows, and wires each to its handler.

### Task 14: `ContactActionCoordinator` with resolution logic

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/Contact/ContactActionCoordinator.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Features/Chats/Viewers/ContactActionCoordinatorTests.swift`
- Modify: `ios/Sanchr-iOS/Tests/UnitTests/TestDoubles.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/UnitTests/Features/Chats/Viewers/ContactActionCoordinatorTests.swift`:

```swift
import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ContactActionCoordinatorTests: XCTestCase {

    func test_present_resolvesSanchrUserFromContacts() async {
        let contacts = FakeContactRepository(users: [
            User(id: "u1", phoneNumber: "+919876543210", displayName: "Alice", isLocalUser: false)
        ])
        let coord = ContactActionCoordinator(
            contactRepository: contacts,
            deviceContactMatcher: { _ in false },
            currentUserId: { "u-me" },
            phoneNormalizer: { $0.filter { $0.isNumber || $0 == "+" } }
        )

        await coord.present(name: "Alice", phoneNumber: "+91 98765 43210")

        XCTAssertEqual(coord.pendingContact?.resolvedSanchrUserId, "u1")
        XCTAssertEqual(coord.pendingContact?.alreadyInDeviceContacts, false)
        XCTAssertFalse(coord.pendingContact?.isSelfContact ?? true)
    }

    func test_present_marksAlreadyInDeviceContacts() async {
        let contacts = FakeContactRepository(users: [])
        let coord = ContactActionCoordinator(
            contactRepository: contacts,
            deviceContactMatcher: { _ in true },
            currentUserId: { "u-me" },
            phoneNormalizer: { $0 }
        )

        await coord.present(name: "Bob", phoneNumber: "+15551234")

        XCTAssertEqual(coord.pendingContact?.alreadyInDeviceContacts, true)
        XCTAssertNil(coord.pendingContact?.resolvedSanchrUserId)
    }

    func test_present_detectsSelfContact() async {
        let contacts = FakeContactRepository(users: [
            User(id: "u-me", phoneNumber: "+919876543210", displayName: "Me", isLocalUser: true)
        ])
        let coord = ContactActionCoordinator(
            contactRepository: contacts,
            deviceContactMatcher: { _ in false },
            currentUserId: { "u-me" },
            phoneNormalizer: { $0 }
        )

        await coord.present(name: "Me", phoneNumber: "+919876543210")

        XCTAssertTrue(coord.pendingContact?.isSelfContact ?? false)
    }

    func test_dismiss_clearsPending() async {
        let coord = ContactActionCoordinator(
            contactRepository: FakeContactRepository(users: []),
            deviceContactMatcher: { _ in false },
            currentUserId: { nil },
            phoneNormalizer: { $0 }
        )
        await coord.present(name: "X", phoneNumber: "+1")
        coord.dismiss()
        XCTAssertNil(coord.pendingContact)
    }
}

private final class FakeContactRepository: ContactRepositoryProtocol, @unchecked Sendable {
    let users: [User]
    init(users: [User]) { self.users = users }
    func fetchContacts() async throws -> [User] { users }

    // BEFORE WRITING THIS FAKE: open `Shared/Repositories/ContactRepository.swift`
    // and copy every method signature from `ContactRepositoryProtocol` into
    // this fake. Stub each one as `fatalError("not exercised")`. This fake
    // is only used by `ContactActionCoordinatorTests` which only calls
    // `fetchContacts()` — any other call is a test bug, not a legitimate
    // path, so fatalError is correct. Do NOT leave any method unimplemented;
    // Swift will fail compilation and tell you what's missing.
}
```

- [ ] **Step 2: Run tests — confirm compile failures**

Expected: `ContactActionCoordinator` not found, `PhoneNumberNormalizer` etc.

- [ ] **Step 3: Create `ContactActionCoordinator.swift`**

```swift
import Foundation
import Contacts
import SanchrShared

@MainActor
final class ContactActionCoordinator: ObservableObject {
    @Published var pendingContact: PendingContact?

    struct PendingContact: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let phoneNumber: String
        let normalizedPhone: String
        let resolvedSanchrUserId: String?
        let resolvedSanchrUser: User?
        let alreadyInDeviceContacts: Bool
        let isSelfContact: Bool
    }

    private let contactRepository: ContactRepositoryProtocol
    private let deviceContactMatcher: @Sendable (String) -> Bool
    private let currentUserId: @Sendable () -> String?
    private let phoneNormalizer: @Sendable (String) -> String

    init(
        contactRepository: ContactRepositoryProtocol,
        deviceContactMatcher: @escaping @Sendable (String) -> Bool,
        currentUserId: @escaping @Sendable () -> String?,
        phoneNormalizer: @escaping @Sendable (String) -> String
    ) {
        self.contactRepository = contactRepository
        self.deviceContactMatcher = deviceContactMatcher
        self.currentUserId = currentUserId
        self.phoneNormalizer = phoneNormalizer
    }

    func present(name: String, phoneNumber: String) async {
        let normalized = phoneNormalizer(phoneNumber)
        let users = (try? await contactRepository.fetchContacts()) ?? []
        let match = users.first { user in
            guard let p = user.phoneNumber else { return false }
            return phoneNormalizer(p) == normalized
        }
        let meId = currentUserId()
        let isSelf = (match?.id == meId) && meId != nil
        pendingContact = PendingContact(
            name: name,
            phoneNumber: phoneNumber,
            normalizedPhone: normalized,
            resolvedSanchrUserId: (isSelf ? nil : match?.id),
            resolvedSanchrUser: isSelf ? nil : match,
            alreadyInDeviceContacts: deviceContactMatcher(normalized),
            isSelfContact: isSelf
        )
    }

    func dismiss() {
        pendingContact = nil
    }
}
```

- [ ] **Step 4: Check that `User` has a `phoneNumber` property — adjust if different**

Grep `SanchrShared/Models/User.swift`. If the real property is `phone` or similar, adapt the matching closure in `present(name:phoneNumber:)` and the test's `FakeContactRepository` accordingly. (Do not guess — read the file.)

- [ ] **Step 5: Run tests**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:SanchrTests/ContactActionCoordinatorTests 2>&1 | tail -5
```
Expected: all four tests pass.

- [ ] **Step 6: Commit**

```bash
git add Features/Chats/Presentation/Viewers/Contact/ContactActionCoordinator.swift \
        Tests/UnitTests/Features/Chats/Viewers/ContactActionCoordinatorTests.swift
git commit -m "feat(chats): add ContactActionCoordinator with Sanchr + device matching"
```

---

### Task 15: `ContactActionSheet` SwiftUI view + CNContactViewController host

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/Contact/ContactActionSheet.swift`
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/Contact/ContactViewControllerHost.swift`

- [ ] **Step 1: Create the `CNContactViewController` host**

```swift
import SwiftUI
import Contacts
import ContactsUI

/// `CNContactViewController` wrapper. Supports three modes: new-contact
/// (pre-filled), existing-contact (read-only), and unknown-contact (pre-
/// filled without forcing a save). The `ContactActionSheet` picks the
/// mode from the `PendingContact` state.
struct ContactViewControllerHost: UIViewControllerRepresentable {
    enum Mode {
        case newContact(name: String, phone: String)
        case existing(CNContact)
    }

    let mode: Mode
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc: CNContactViewController
        switch mode {
        case .newContact(let name, let phone):
            let contact = CNMutableContact()
            let components = name.split(separator: " ", maxSplits: 1).map(String.init)
            contact.givenName = components.first ?? name
            contact.familyName = components.count > 1 ? components[1] : ""
            contact.phoneNumbers = [
                CNLabeledValue(
                    label: CNLabelPhoneNumberMobile,
                    value: CNPhoneNumber(stringValue: phone)
                )
            ]
            vc = CNContactViewController(forNewContact: contact)
        case .existing(let contact):
            vc = CNContactViewController(for: contact)
        }
        vc.delegate = context.coordinator
        let nav = UINavigationController(rootViewController: vc)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }
        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            onDismiss()
        }
    }
}
```

- [ ] **Step 2: Create `ContactActionSheet.swift`**

```swift
import SwiftUI
import UIKit
import SanchrShared

struct ContactActionSheet: View {
    let pending: ContactActionCoordinator.PendingContact
    let onMessageOnSanchr: (String) -> Void       // userId
    let onInvite: () -> Void
    let onOpenNewContact: (String, String) -> Void // name, phone
    let onOpenExistingContact: () -> Void
    let onDismiss: () -> Void

    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }

                Section {
                    if let userId = pending.resolvedSanchrUserId, !pending.isSelfContact {
                        row(icon: "message.fill", text: "Message on Sanchr", color: .sanchrPrimary) {
                            onMessageOnSanchr(userId)
                        }
                    } else if !pending.isSelfContact {
                        row(icon: "paperplane.fill", text: "Invite to Sanchr", color: .sanchrPrimary) {
                            onInvite()
                        }
                    }

                    if pending.alreadyInDeviceContacts {
                        row(icon: "person.crop.circle", text: "View in Contacts", color: .primary) {
                            onOpenExistingContact()
                        }
                    } else {
                        row(icon: "person.crop.circle.badge.plus", text: "Save to Contacts", color: .primary) {
                            onOpenNewContact(pending.name, pending.phoneNumber)
                        }
                    }

                    row(icon: "phone.fill", text: "Call", color: .primary) {
                        open(url: URL(string: "tel://\(pending.normalizedPhone)"))
                    }
                    row(icon: "message", text: "Send SMS", color: .primary) {
                        open(url: URL(string: "sms://\(pending.normalizedPhone)"))
                    }
                    row(icon: "doc.on.doc", text: "Copy number", color: .primary) {
                        UIPasteboard.general.string = pending.phoneNumber
                        toast = "Number copied"
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 32)
                        .task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { self.toast = nil }
                        }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(pending.name).font(.headline)
                Text(pending.phoneNumber).font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func row(icon: String, text: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 24).foregroundColor(color)
                Text(text).foregroundColor(color)
                Spacer()
            }
        }
    }

    private func open(url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Features/Chats/Presentation/Viewers/Contact/ContactActionSheet.swift \
        Features/Chats/Presentation/Viewers/Contact/ContactViewControllerHost.swift
git commit -m "feat(chats): add ContactActionSheet and CNContactViewController host"
```

---

### Task 16: Wire contact coordinator into `ChatDetailView` + `MessageRepository.startDirectConversation`

**Files:**
- Modify: `ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Add `startDirectConversation` to `MessageRepositoryProtocol` and impl**

In `Shared/Repositories/MessageRepository.swift`, add to the protocol:

```swift
    /// Creates (or fetches existing) 1:1 conversation with `peerUserId` via
    /// the `StartDirectConversation` RPC. Returns the server-assigned
    /// conversation id so the caller can deep-link into it.
    func startDirectConversation(peerUserId: String) async throws -> String
```

In `MessageRepositoryImpl`, add the method body — check `project.yml` and the generated client to confirm exact request field names:

```swift
    func startDirectConversation(peerUserId: String) async throws -> String {
        var request = Vync_Messaging_StartDirectConversationRequest()
        request.peerUserID = peerUserId
        let response = try await grpcClient.messagingService.startDirectConversation(request)
        return response.id
    }
```

If `StartDirectConversationRequest`'s field is named differently (e.g. `recipientID`), use the name from `SanchrShared/Generated/messaging.pb.swift`. Same for `response.id` — the returned `Vync_Messaging_Conversation` field is likely `id`. Grep the generated files to confirm and adjust.

- [ ] **Step 2: Mount the contact coordinator in `ChatDetailView`**

Next to the existing `@StateObject private var galleryCoordinator`, add:

```swift
    @StateObject private var contactCoordinator: ContactActionCoordinator
```

Add an explicit `init()` that constructs the coordinator with dependencies from the environment — SwiftUI `@StateObject` can't access `@Environment` in its initializer, so instead we construct it lazily. Replace the `@StateObject` with:

```swift
    @StateObject private var contactCoordinator = ContactActionCoordinator(
        contactRepository: _deferredContactRepository,
        deviceContactMatcher: _deferredDeviceContactMatcher,
        currentUserId: _deferredCurrentUserId,
        phoneNormalizer: _deferredPhoneNormalizer
    )
```

This looks awkward because it is — `@StateObject` can't see `container` at init time. A cleaner alternative: make the coordinator's dependencies swappable after init, OR build the coordinator in `.task { ... }`. Use the latter — declare the `@StateObject` as a no-op default and configure it in `.task`:

```swift
    @StateObject private var contactCoordinator = ContactActionCoordinator(
        contactRepository: EmptyContactRepository(),
        deviceContactMatcher: { _ in false },
        currentUserId: { nil },
        phoneNormalizer: { $0 }
    )
```

Then add a private helper `EmptyContactRepository` at the bottom of the same file. The bootstrap repository is only active for a single SwiftUI update cycle — between `@StateObject` init and the `.task` reconfigure — so every non-used method can safely `fatalError`.

**Before writing `EmptyContactRepository`:** open `Shared/Repositories/ContactRepository.swift`, copy each method signature from `ContactRepositoryProtocol`, and add them below. Each unused method body is `fatalError("ChatDetailView bootstrap repo should never be called")`. The `fetchContacts` method is the only one that may fire during the brief bootstrap window — return an empty array.

```swift
private final class EmptyContactRepository: ContactRepositoryProtocol, @unchecked Sendable {
    func fetchContacts() async throws -> [User] { [] }
    // Fill in every other protocol method with:
    //   fatalError("ChatDetailView bootstrap repo should never be called")
    // Compilation will surface any you miss.
}
```

Finally, rebuild the coordinator with real dependencies in `.task` after `container` is available. The cleanest approach is to add a public `reconfigure(...)` method on `ContactActionCoordinator`:

```swift
    func reconfigure(
        contactRepository: ContactRepositoryProtocol,
        deviceContactMatcher: @escaping @Sendable (String) -> Bool,
        currentUserId: @escaping @Sendable () -> String?,
        phoneNormalizer: @escaping @Sendable (String) -> String
    ) {
        self.contactRepository = contactRepository
        self.deviceContactMatcher = deviceContactMatcher
        self.currentUserId = currentUserId
        self.phoneNormalizer = phoneNormalizer
    }
```

Mark the four stored properties `var` instead of `let`. Then in `ChatDetailView.body`'s `.task`, call:

```swift
            contactCoordinator.reconfigure(
                contactRepository: container.contactRepository,
                deviceContactMatcher: { phone in
                    DeviceContactMatcher.shared.contains(phone: phone)
                },
                currentUserId: { container.sessionService.currentUserId },
                phoneNormalizer: ContactDataSource.normalizePhone
            )
```

`DeviceContactMatcher` is a tiny new wrapper — inline it in the same file for now:

```swift
private struct DeviceContactMatcher {
    static let shared = DeviceContactMatcher()
    func contains(phone: String) -> Bool {
        let store = CNContactStore()
        let keys = [CNContactPhoneNumbersKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var found = false
        try? store.enumerateContacts(with: request) { contact, stop in
            for number in contact.phoneNumbers {
                if number.value.stringValue.filter(\.isNumber) == phone.filter(\.isNumber) {
                    found = true
                    stop.pointee = true
                    return
                }
            }
        }
        return found
    }
}
```

`ContactDataSource.normalizePhone` — check `Features/Contacts/Data/ContactDataSource.swift` line ~95 for the exact name of the normalize/hash helper. If it's `private static func normalize(_:)`, temporarily change it to `internal` and reference it. If it's already folded inside `hashPhoneNumber`, extract the pure normalization step (string-only, no SHA256) into a new `static func normalize(_:)` and keep `hashPhoneNumber` calling it.

- [ ] **Step 3: Update the view model `route` closure in `MessageCollectionView(...)` call**

Extend the `onBubbleTap` closure body:

```swift
                onBubbleTap: { interaction in
                    viewModel.route(
                        interaction: interaction,
                        onOpenGallery: { seed in galleryCoordinator.present(seed: seed) },
                        onOpenContact: { name, phone in
                            Task { await contactCoordinator.present(name: name, phoneNumber: phone) }
                        }
                    )
                }
```

- [ ] **Step 4: Mount the sheet**

After the `.fullScreenCover` for gallery, add:

```swift
        .sheet(item: $contactCoordinator.pendingContact) { pending in
            ContactActionSheet(
                pending: pending,
                onMessageOnSanchr: { userId in
                    Task {
                        do {
                            let convId = try await container.messageRepository.startDirectConversation(peerUserId: userId)
                            contactCoordinator.dismiss()
                            router.deepLinkToConversation(conversationId: convId)
                        } catch {
                            SanchrLogger.chat.error("startDirectConversation failed: \(error.localizedDescription)")
                        }
                    }
                },
                onInvite: {
                    contactCoordinator.dismiss()
                    presentInviteShareSheet(for: pending)
                },
                onOpenNewContact: { name, phone in
                    presentingNewContact = (name, phone)
                },
                onOpenExistingContact: {
                    presentingExistingContactPhone = pending.normalizedPhone
                },
                onDismiss: { contactCoordinator.dismiss() }
            )
        }
```

Add the three support `@State` vars and two presentation sheets — `presentingNewContact: (String, String)?`, `presentingExistingContactPhone: String?`, plus `.sheet(item:)` bindings driving `ContactViewControllerHost`. Use a tiny `IdentifiedPair` struct if needed to make the tuple Identifiable.

Add `router.deepLinkToConversation` — check if `AppRouter` has a method of that shape. If it's currently `routeNotificationAction(.openConversation(id))`, reuse that. Otherwise add a new small helper:

```swift
    func deepLinkToConversation(conversationId: String) {
        selectedTab = .chats
        pendingConversationId = conversationId
    }
```

in `AppRouter.swift` next to `routeNotificationAction`.

- [ ] **Step 5: Implement `presentInviteShareSheet`**

Add near the other helpers in `ChatDetailView`:

```swift
    @State private var invitePayload: IdentifiedURL?

    private func presentInviteShareSheet(for pending: ContactActionCoordinator.PendingContact) {
        let url = URL(string: "https://sanchr.io/invite?from=chat")!
        invitePayload = IdentifiedURL(url: url)
    }
```

And add `.sheet(item: $invitePayload) { wrapped in ActivityView(items: ["Join me on Sanchr — \(wrapped.url)"]) }` next to the other sheet bindings. (`IdentifiedURL` and `ActivityView` from Task 13 are file-private to that file — duplicate them at the bottom of `ChatDetailView.swift` since cross-file sharing isn't worth the refactor for two 10-line structs.)

- [ ] **Step 6: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Manual smoke**

Send yourself a contact card from another device. Tap it — the action sheet appears. If the number is a Sanchr user, "Message on Sanchr" is present; tap it → pops into the chats tab and opens the chat. If not, "Invite to Sanchr" shows instead → opens the share sheet. "Save to Contacts" opens `CNContactViewController` prefilled. Call / SMS / Copy all work.

- [ ] **Step 8: Commit**

```bash
git add Shared/Repositories/MessageRepository.swift \
        App/AppRouter.swift \
        Features/Chats/Presentation/ChatDetailView.swift
git commit -m "feat(chats): wire ContactActionSheet with Sanchr deep-link + invite"
```

**End of Phase 4** — contact bubbles now open a fully functional action sheet with all four row classes.

---

## Phase 5 — Location viewer

Goal: tapping a location bubble opens an inline MapKit preview with a bottom card and share button; share opens the Apple/Google/Copy action sheet.

### Task 17: `LocationPreviewCoordinator`

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/Location/LocationPreviewCoordinator.swift`

- [ ] **Step 1: Create the coordinator**

```swift
import SwiftUI

@MainActor
final class LocationPreviewCoordinator: ObservableObject {
    @Published var presentation: LocationPresentation?

    struct LocationPresentation: Identifiable, Equatable {
        let id = UUID()
        let latitude: Double
        let longitude: Double
    }

    func present(latitude: Double, longitude: Double) {
        presentation = LocationPresentation(
            latitude: latitude,
            longitude: longitude
        )
    }

    func dismiss() {
        presentation = nil
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Features/Chats/Presentation/Viewers/Location/LocationPreviewCoordinator.swift
git commit -m "feat(chats): add LocationPreviewCoordinator"
```

---

### Task 18: `LocationPreviewView` with Map + reverse-geocode + action sheet

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/Location/LocationPreviewView.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import MapKit
import CoreLocation
import UIKit

struct LocationPreviewView: View {
    let latitude: Double
    let longitude: Double
    let onDismiss: () -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var placeName: String?
    @State private var toast: String?
    @State private var showActionSheet = false

    init(latitude: Double, longitude: Double, onDismiss: @escaping () -> Void) {
        self.latitude = latitude
        self.longitude = longitude
        self.onDismiss = onDismiss
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        self._cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // `Map(position:)` in iOS 17+ does NOT render the receiver's own
            // blue-dot location by default — the old `Map(coordinateRegion:
            // showsUserLocation:)` initializer is the only one that ever did.
            // By using the position initializer and NOT declaring a
            // `UserAnnotation()` inside the map content, we satisfy the
            // spec's "receiver's own position must never be rendered"
            // hardening requirement without needing an explicit flag.
            // Do NOT add `UserAnnotation()` to this block.
            Map(position: $cameraPosition) {
                Marker(
                    placeName ?? "Shared location",
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                )
                .tint(.sanchrPrimary)
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()

            HStack {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 36, height: 36)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(radius: 4, y: 2)
                }
                Spacer()
                Button { showActionSheet = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 36, height: 36)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(radius: 4, y: 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
        }
        .overlay(alignment: .bottom) {
            locationCard
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .padding(.bottom, 120)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .confirmationDialog(
            "Open location",
            isPresented: $showActionSheet,
            titleVisibility: .visible
        ) {
            Button("Open in Apple Maps") { openInAppleMaps() }
            Button("Open in Google Maps") { openInGoogleMaps() }
            Button("Copy Coordinates") { copyCoordinates() }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await reverseGeocode()
        }
    }

    @ViewBuilder
    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let placeName {
                Text(placeName)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            Text(String(format: "%.4f°, %.4f°", latitude, longitude))
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                showActionSheet = true
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    Text("Directions")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundColor(.white)
                .background(Color.sanchrPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    // MARK: - Actions

    private func openInAppleMaps() {
        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = placeName ?? "Shared location"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    private func openInGoogleMaps() {
        let appURL = URL(string: "comgooglemaps://?q=\(latitude),\(longitude)&center=\(latitude),\(longitude)&zoom=15")
        let webURL = URL(string: "https://maps.google.com/?q=\(latitude),\(longitude)")
        if let appURL, UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL {
            UIApplication.shared.open(webURL)
        }
    }

    private func copyCoordinates() {
        UIPasteboard.general.string = String(format: "%.6f, %.6f", latitude, longitude)
        toast = "Coordinates copied"
    }

    @MainActor
    private func reverseGeocode() async {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let parts = [placemark.name, placemark.locality].compactMap { $0 }
                placeName = parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        } catch {
            // Silent: card falls back to coordinates only.
        }
    }
}
```

- [ ] **Step 2: Mount the coordinator + view in `ChatDetailView`**

Add:

```swift
    @StateObject private var locationCoordinator = LocationPreviewCoordinator()
```

Extend the `route` callbacks in the `MessageCollectionView` `onBubbleTap`:

```swift
                        onOpenLocation: { lat, lon in
                            locationCoordinator.present(latitude: lat, longitude: lon)
                        },
```

Mount after the other sheets:

```swift
        .fullScreenCover(item: $locationCoordinator.presentation) { presentation in
            LocationPreviewView(
                latitude: presentation.latitude,
                longitude: presentation.longitude,
                onDismiss: { locationCoordinator.dismiss() }
            )
        }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual smoke**

Send a location bubble from another device. Tap it → fullscreen map with pin. Bottom card shows place name after ~1s. Share button → action sheet with Apple / Google / Copy / Cancel. Copy toast appears. Apple Maps launches with directions. Google Maps opens in-app if installed, else Safari.

- [ ] **Step 5: Commit**

```bash
git add Features/Chats/Presentation/Viewers/Location/LocationPreviewView.swift \
        Features/Chats/Presentation/ChatDetailView.swift
git commit -m "feat(chats): add LocationPreviewView with MapKit + Apple/Google action sheet"
```

**End of Phase 5** — location bubbles now open a full preview.

---

## Phase 6 — Document viewer

Goal: tapping a document bubble downloads and decrypts via the resolver (named copy), presents QuickLook with the original filename, falls through to `UIDocumentInteractionController` for unsupported formats.

### Task 19: `DocumentPreviewCoordinator`

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/Document/DocumentPreviewCoordinator.swift`

- [ ] **Step 1: Create the coordinator**

```swift
import SwiftUI
import SanchrShared

@MainActor
final class DocumentPreviewCoordinator: ObservableObject {
    @Published var presentation: DocumentPresentation?
    @Published var isResolving: Bool = false
    @Published var resolveError: String?

    struct DocumentPresentation: Identifiable, Equatable {
        let id = UUID()
        let fileURL: URL
    }

    private let resolver: ChatMediaResolving
    private let messageLookup: @Sendable (String) -> Message?

    init(
        resolver: ChatMediaResolving,
        messageLookup: @escaping @Sendable (String) -> Message?
    ) {
        self.resolver = resolver
        self.messageLookup = messageLookup
    }

    func open(messageId: String) async {
        guard let message = messageLookup(messageId),
              case .document(let attachment) = message.content else {
            resolveError = "Attachment not found."
            return
        }
        isResolving = true
        defer { isResolving = false }
        do {
            let url = try await resolver.decryptedURLWithDisplayName(
                forMessageId: messageId,
                attachment: attachment
            )
            presentation = DocumentPresentation(fileURL: url)
        } catch {
            resolveError = error.localizedDescription
        }
    }

    func dismiss() {
        presentation = nil
    }

    func clearError() {
        resolveError = nil
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
git add Features/Chats/Presentation/Viewers/Document/DocumentPreviewCoordinator.swift
git commit -m "feat(chats): add DocumentPreviewCoordinator"
```

---

### Task 20: `DocumentPreviewView` (QuickLook + fallback)

**Files:**
- Create: `ios/Sanchr-iOS/Features/Chats/Presentation/Viewers/Document/DocumentPreviewView.swift`
- Modify: `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift`

- [ ] **Step 1: Create the QuickLook wrapper**

```swift
import SwiftUI
import QuickLook
import UIKit

struct DocumentPreviewView: UIViewControllerRepresentable {
    let fileURL: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if QLPreviewController.canPreview(fileURL as NSURL) {
            let ql = QLPreviewController()
            ql.dataSource = context.coordinator
            ql.delegate = context.coordinator
            let nav = UINavigationController(rootViewController: ql)
            ql.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: context.coordinator,
                action: #selector(Coordinator.doneTapped)
            )
            return nav
        } else {
            // Fallback: hand-off via document interaction controller so the
            // user at least gets "Open In…" for proprietary formats.
            let host = UIViewController()
            host.view.backgroundColor = .systemBackground
            DispatchQueue.main.async {
                let interaction = UIDocumentInteractionController(url: fileURL)
                context.coordinator.interaction = interaction
                interaction.delegate = context.coordinator
                interaction.presentOptionsMenu(from: host.view.bounds, in: host.view, animated: true)
            }
            return host
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject,
                              QLPreviewControllerDataSource,
                              QLPreviewControllerDelegate,
                              UIDocumentInteractionControllerDelegate {
        let fileURL: URL
        let onDismiss: () -> Void
        var interaction: UIDocumentInteractionController?

        init(fileURL: URL, onDismiss: @escaping () -> Void) {
            self.fileURL = fileURL
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            fileURL as NSURL
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onDismiss()
        }

        @objc func doneTapped() {
            onDismiss()
        }

        func documentInteractionControllerViewControllerForPreview(
            _ controller: UIDocumentInteractionController
        ) -> UIViewController {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first ?? UIViewController()
        }

        func documentInteractionControllerDidDismissOptionsMenu(
            _ controller: UIDocumentInteractionController
        ) {
            onDismiss()
        }
    }
}
```

- [ ] **Step 2: Add `reconfigure` on `DocumentPreviewCoordinator`**

Change the two stored properties to `var`:

```swift
    private var resolver: ChatMediaResolving
    private var messageLookup: @Sendable (String) -> Message?
```

And add:

```swift
    func reconfigure(
        resolver: ChatMediaResolving,
        messageLookup: @escaping @Sendable (String) -> Message?
    ) {
        self.resolver = resolver
        self.messageLookup = messageLookup
    }
```

- [ ] **Step 3: Add a bootstrap `NoopMediaResolver` at the bottom of `ChatDetailView.swift`**

Same bootstrap pattern as `EmptyContactRepository` in Task 16. The bootstrap resolver is only live for the instant between `@StateObject` init and `.task` reconfigure — no real call can reach it. All methods fatalError.

```swift
private final class NoopMediaResolver: ChatMediaResolving, @unchecked Sendable {
    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        fatalError("ChatDetailView bootstrap resolver should never be called")
    }
    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        fatalError("ChatDetailView bootstrap resolver should never be called")
    }
}
```

- [ ] **Step 4: Mount the coordinator and sheet in `ChatDetailView`**

Declare it next to the other `@StateObject`s:

```swift
    @StateObject private var documentCoordinator = DocumentPreviewCoordinator(
        resolver: NoopMediaResolver(),
        messageLookup: { _ in nil }
    )
```

Reconfigure inside the same `.task` modifier that reconfigures `contactCoordinator`:

```swift
            documentCoordinator.reconfigure(
                resolver: container.chatMediaResolver,
                messageLookup: { [weak viewModel] id in
                    viewModel?.messages.first(where: { $0.id == id })
                }
            )
```

Extend `onBubbleTap` to handle `onOpenDocument`:

```swift
                        onOpenDocument: { messageId in
                            Task { await documentCoordinator.open(messageId: messageId) }
                        }
```

Mount the sheet + progress overlay:

```swift
        .fullScreenCover(item: $documentCoordinator.presentation) { presentation in
            DocumentPreviewView(
                fileURL: presentation.fileURL,
                onDismiss: { documentCoordinator.dismiss() }
            )
        }
        .overlay {
            if documentCoordinator.isResolving {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay(ProgressView().tint(.white))
            }
        }
        .alert("Couldn't open file", isPresented: Binding(
            get: { documentCoordinator.resolveError != nil },
            set: { if !$0 { documentCoordinator.clearError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(documentCoordinator.resolveError ?? "")
        }
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Manual smoke**

Send a PDF from another device (name it `Invoice Q4.pdf`). Tap the bubble → progress spinner while it downloads → QuickLook opens with title "Invoice Q4.pdf" (not a UUID). Tap Done → back to chat. Repeat with a `.docx` and confirm QuickLook handles it. Test unsupported type to verify fall-through to `UIDocumentInteractionController` options menu.

- [ ] **Step 7: Commit**

```bash
git add Features/Chats/Presentation/Viewers/Document/DocumentPreviewView.swift \
        Features/Chats/Presentation/Viewers/Document/DocumentPreviewCoordinator.swift \
        Features/Chats/Presentation/ChatDetailView.swift
git commit -m "feat(chats): add DocumentPreviewView with QuickLook + fallback"
```

**End of Phase 6** — document bubbles now open QuickLook with the original filename preserved.

---

## Phase 7 — End-to-end smoke + final polish

Goal: verify every rich bubble routes correctly by running the full test suite, smoke-test all five interaction paths on device, and fix any loose ends found.

### Task 21: Full test suite + manual smoke matrix

**Files:** none — verification only.

- [ ] **Step 1: Run the full unit test suite**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme SanchrTests -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`. Any pre-existing failures (e.g. `AttachmentPickerViewStructuralTests`, `LocationSourceTests` noted in the project context) are NOT regressions from this work — leave them unless they're new. If any new test fails, go back to the phase that added it and fix.

- [ ] **Step 2: Device build**

```bash
xcodebuild -project Sanchr.xcodeproj -scheme Sanchr -destination 'generic/platform=iOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke matrix on a real device (or arm64 sim)**

Run through this table with two accounts. Fail any row → go back to the relevant phase.

| # | Action | Expected |
|---|---|---|
| 1 | Tap a received image | Gallery opens, pinch-zooms, pans, double-tap toggles zoom, swipe to next image works, swipe down dismisses |
| 2 | Tap a received video | Gallery opens, AVPlayerVC native controls appear, scrub works, PiP button works |
| 3 | Tap `⋯ → Save to Photos` on an image | Permission prompt (first time), toast "Image saved to Photos", image appears in Photos app |
| 4 | Tap `⋯ → Share` | System share sheet appears |
| 5 | Tap `⋯ → Copy` on an image | Pasting in Messages pastes the image |
| 6 | Tap a received contact bubble (registered) | Sheet appears with "Message on Sanchr" row |
| 7 | Tap "Message on Sanchr" | Pops to chats tab, opens the 1:1 chat with that user |
| 8 | Tap a received contact bubble (unregistered) | Sheet shows "Invite to Sanchr" instead |
| 9 | Tap "Save to Contacts" | `CNContactViewController` opens prefilled |
| 10 | Tap "Call" | Native call sheet appears |
| 11 | Tap "Copy number" | Toast appears, pasting gives the phone |
| 12 | Tap a location bubble | Map opens with pin, bottom card, reverse-geocoded place name |
| 13 | Tap the share button on location viewer | Action sheet: Apple / Google / Copy / Cancel |
| 14 | Tap "Open in Apple Maps" | Apple Maps launches with directions |
| 15 | Tap "Open in Google Maps" | Google Maps launches if installed, else Safari |
| 16 | Tap "Copy Coordinates" | Toast, clipboard has the coordinates |
| 17 | Tap a received PDF bubble | Progress overlay → QuickLook opens → title shows original filename |
| 18 | Tap "Done" in QuickLook | Returns to chat |
| 19 | Tap an unsupported file type | Fallback `UIDocumentInteractionController` options menu appears |

- [ ] **Step 4: Commit any fixes**

If fixes were needed, commit them in targeted commits:

```bash
git add <fixed files>
git commit -m "fix(chats): <specific fix>"
```

- [ ] **Step 5: Final sanity commit if nothing to fix**

Empty commit is OK as a milestone marker:

```bash
git commit --allow-empty -m "chore: bubble interactions + viewers feature complete"
```

**End of Phase 7** — feature is complete and manually verified.

---

## Deviations from the spec

- **Spec §8 proposed XCUITest smoke tests for the four viewer entry points. The plan replaces those with the manual smoke matrix in Phase 7 Task 21.** Rationale: XCUITest can't reliably drive pinch, pan, and swipe-down-to-dismiss gestures on a `TabView(.page)` pager; it also can't verify `CNContactViewController` / `QLPreviewController` / `AVPlayerViewController` content because they render in separate processes. A manual matrix covers every path without producing flaky tests. Unit-test coverage of the routing layer, gallery seeding, contact resolution, and resolver filename fidelity still lives in the plan as Tasks 4, 6, 14, and 5 respectively.
- **Spec §5.3 calls for an explicit `showsUserLocation = false`.** iOS 17 `Map(position:)` doesn't render the user location dot unless you add a `UserAnnotation()` to the map builder. The plan enforces this with a comment in Task 18 and a "do not add `UserAnnotation()`" rule rather than a property setter, because there is no such property on the `position` initializer.
- **Spec §4.3 describes the cache layout as `full/<mediaId>/<originalFilename>`.** The plan uses a hard-link into a separate display directory (`<tmp>/sanchr-quicklook/<messageId>/<filename>`) pointing at the existing `MediaDownloadManager` cache entry. Functionally equivalent, zero extra bytes, zero changes to the existing download cache layout. Documented in Task 5.

---

## Out of scope (not in this plan)

These were explicitly deferred in the spec and must NOT be added during implementation:

- Forward / reply / pin / star from inside viewers (context menu handles these).
- Multi-image select in gallery for batch save/share.
- Custom PDF reader with thumbnails sidebar (QuickLook is sufficient).
- In-viewer captions editing.
- Video trimming / export.
- Baking a map snapshot into the location bubble thumbnail itself.
- Feature flag gating — ships behind no flag since there's no existing behavior to A/B.
