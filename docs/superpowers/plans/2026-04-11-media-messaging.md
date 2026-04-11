# Encrypted Media Messaging — Pre-Send Caption UI & Test Coverage

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the encrypted media messaging feature by adding a pre-send caption/preview screen for images and videos, and fill the test gap for image, video, and document send paths.

**Architecture:** The full encrypt-upload-send and download-decrypt-display pipeline already exists in `MessageSender`, `MediaUploadManager`, `MediaDownloadManager`, `MediaEncryptor`, and `MediaGalleryView`. The only missing UX piece is a caption entry screen between photo/video pick and send (Signal-style: full-screen preview with caption text field). This plan adds `MediaCaptionView` (new file), modifies intent routing in `ChatDetailView`, and adds unit tests for image/video/document send paths to `MessageSenderTests`.

**Tech Stack:** Swift, SwiftUI, AVKit, XCTest

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Tests/UnitTests/MessageSenderTests.swift` | Modify | Add 4 new `sendMedia` tests: image key round-trip, video content-type, document content-type, caption stored |
| `Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift` | **Create** | Full-screen pre-send preview: image or video + caption text field + Send/Cancel |
| `Features/Chats/Presentation/ChatDetailView.swift` | Modify | Add `pendingMediaSend` state; intercept image/video send to show caption screen first |

---

### Task 1: Fill the sendMedia test gap

**Files:**
- Modify: `Tests/UnitTests/MessageSenderTests.swift`

All new tests go inside the existing `MessageSenderTests` class, after the last `// MARK: sendMedia` test. They reuse the existing `FakeLocalDatabase`, `FakeUploader`, `FakeEncryptedSender`, `FakeCurrentUser`, and `makeSUT()` factory already defined in that file.

- [ ] **Step 1: Run the existing sendMedia tests to establish a baseline**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/MessageSenderTests \
  2>&1 | grep -E "FAILED|PASSED|passed|error:" | head -10
```

Expected: All existing tests pass.

- [ ] **Step 2: Read the file to find the exact insertion point**

Read `Tests/UnitTests/MessageSenderTests.swift` lines 410–460 to see where the last sendMedia test ends. Insert the four new tests immediately after it, still inside `MessageSenderTests`.

- [ ] **Step 3: Add the four new test methods**

Append these four methods inside the `MessageSenderTests` class (after `test_sendMedia_uploadFails_marksFailedAndDoesNotCallEncryptedSender`):

```swift
func test_sendMedia_image_happyPath_roundtripsEncryptionKey() async throws {
    let (sut, db, uploader, sender, _) = makeSUT()
    let key   = Data(repeating: 0xAA, count: 32)
    let nonce = Data(repeating: 0xBB, count: 12)
    await uploader.setResult(.success(MediaUploadOutcome(
        mediaId: "img-123",
        remoteURL: "https://example.invalid/img-123",
        thumbnailRemoteURL: nil,
        encryptedFileSize: 4096,
        plaintextFileSize: 2048,
        encryptionKey: key,
        encryptionNonce: nonce,
        encryptionTag: Data(repeating: 0xCC, count: 16),
        plaintextDigest: Data(repeating: 0xDD, count: 32)
    )))
    await sender.setResult(.success(EncryptedMessageSendResult(
        messageId: "server-img-1",
        serverTimestampMs: 1_700_001_000_000
    )))

    let attachment = Message.MediaAttachment(
        url: URL(fileURLWithPath: "/tmp/photo.jpg"),
        encryptionKey: Data(),
        encryptionIV: Data(),
        mimeType: "image/jpeg",
        sizeBytes: 2048,
        width: 1080,
        height: 720,
        blurHash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    )

    _ = try await sut.sendMedia(attachment: attachment, caption: nil, to: "chat-A", progress: { _ in })

    XCTAssertEqual(db.savedMessages.count, 2)
    let confirmed = db.savedMessages[1]
    guard case .image(let stored) = confirmed.content else {
        return XCTFail("Expected .image content on confirmed row")
    }
    XCTAssertEqual(stored.encryptionKey, key,
        "Encryption key must be roundtripped from upload outcome into the stored attachment")
    XCTAssertEqual(stored.encryptionIV, nonce,
        "Encryption nonce must be roundtripped from upload outcome into the stored attachment")
    XCTAssertEqual(stored.width, 1080, "Image width must be preserved through the send pipeline")
    XCTAssertEqual(stored.height, 720, "Image height must be preserved")
    XCTAssertEqual(stored.blurHash, "LEHV6nWB2yk8pyo0adR*.7kCMdnj", "BlurHash must be preserved for receiver placeholder")
    XCTAssertEqual(stored.url.absoluteString, "sanchr-media://img-123",
        "URL must be rewritten to sanchr-media:// scheme after upload")
}

func test_sendMedia_video_usesVideoContentTypeString() async throws {
    let (sut, db, uploader, sender, _) = makeSUT()
    await uploader.setResult(.success(MediaUploadOutcome(
        mediaId: "vid-456",
        remoteURL: "https://example.invalid/vid-456",
        thumbnailRemoteURL: nil,
        encryptedFileSize: 8192,
        plaintextFileSize: 4096,
        encryptionKey: Data(repeating: 0x01, count: 32),
        encryptionNonce: Data(repeating: 0x02, count: 12),
        encryptionTag: Data(repeating: 0x03, count: 16),
        plaintextDigest: Data(repeating: 0x04, count: 32)
    )))
    await sender.setResult(.success(EncryptedMessageSendResult(
        messageId: "server-vid-1",
        serverTimestampMs: 1_700_002_000_000
    )))

    let attachment = Message.MediaAttachment(
        url: URL(fileURLWithPath: "/tmp/video.mp4"),
        encryptionKey: Data(),
        encryptionIV: Data(),
        mimeType: "video/mp4",
        sizeBytes: 4096,
        width: 1920,
        height: 1080,
        durationSeconds: 15.5
    )

    _ = try await sut.sendMedia(attachment: attachment, caption: nil, to: "chat-B", progress: { _ in })

    let calls = await sender.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].contentType, "video",
        "video/mp4 MIME must map to 'video' content type string — required by receive-path decoder")

    // Confirm confirmed row is .video and duration is preserved
    XCTAssertEqual(db.savedMessages.count, 2)
    guard case .video(let stored) = db.savedMessages[1].content else {
        return XCTFail("Expected .video content on confirmed row")
    }
    XCTAssertEqual(stored.durationSeconds, 15.5, "Video duration must be preserved")
}

func test_sendMedia_document_usesDocumentContentTypeAndPreservesFilename() async throws {
    let (sut, db, uploader, sender, _) = makeSUT()
    await uploader.setResult(.success(MediaUploadOutcome(
        mediaId: "doc-789",
        remoteURL: "https://example.invalid/doc-789",
        thumbnailRemoteURL: nil,
        encryptedFileSize: 16_384,
        plaintextFileSize: 8_192,
        encryptionKey: Data(repeating: 0xEE, count: 32),
        encryptionNonce: Data(repeating: 0xFF, count: 12),
        encryptionTag: Data(repeating: 0x10, count: 16),
        plaintextDigest: Data(repeating: 0x20, count: 32)
    )))
    await sender.setResult(.success(EncryptedMessageSendResult(
        messageId: "server-doc-1",
        serverTimestampMs: 1_700_003_000_000
    )))

    let attachment = Message.MediaAttachment(
        url: URL(fileURLWithPath: "/tmp/report.pdf"),
        encryptionKey: Data(),
        encryptionIV: Data(),
        mimeType: "application/pdf",
        sizeBytes: 8_192,
        filename: "Q4-Report.pdf"
    )

    _ = try await sut.sendMedia(attachment: attachment, caption: nil, to: "chat-C", progress: { _ in })

    let calls = await sender.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].contentType, "document",
        "application/pdf MIME must map to 'document' — not image/video/audio")

    XCTAssertEqual(db.savedMessages.count, 2)
    guard case .document(let stored) = db.savedMessages[1].content else {
        return XCTFail("Expected .document content on confirmed row")
    }
    XCTAssertEqual(stored.filename, "Q4-Report.pdf",
        "Filename must survive the upload+rebuild pipeline so the receiver can show it")
}

func test_sendMedia_captionBakedIntoStoredAttachment() async throws {
    let (sut, db, uploader, sender, _) = makeSUT()
    await uploader.setResult(.success(MediaUploadOutcome(
        mediaId: "img-cap",
        remoteURL: "https://example.invalid/img-cap",
        thumbnailRemoteURL: nil,
        encryptedFileSize: 2048,
        plaintextFileSize: 1024,
        encryptionKey: Data(repeating: 0x55, count: 32),
        encryptionNonce: Data(repeating: 0x66, count: 12),
        encryptionTag: Data(repeating: 0x77, count: 16),
        plaintextDigest: Data(repeating: 0x88, count: 32)
    )))
    await sender.setResult(.success(EncryptedMessageSendResult(
        messageId: "server-cap-1",
        serverTimestampMs: 1_700_004_000_000
    )))

    let attachment = Message.MediaAttachment(
        url: URL(fileURLWithPath: "/tmp/sunset.jpg"),
        encryptionKey: Data(),
        encryptionIV: Data(),
        mimeType: "image/jpeg",
        sizeBytes: 1024
    )

    _ = try await sut.sendMedia(
        attachment: attachment,
        caption: "Golden hour 🌅",
        to: "chat-D",
        progress: { _ in }
    )

    XCTAssertEqual(db.savedMessages.count, 2)
    guard case .image(let stored) = db.savedMessages[1].content else {
        return XCTFail("Expected .image content on confirmed row")
    }
    XCTAssertEqual(stored.caption, "Golden hour 🌅",
        "Caption passed to sendMedia must be stored in the confirmed attachment so the receiver can display it")
}
```

- [ ] **Step 4: Run the new tests to verify they pass (pipeline already implemented)**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/MessageSenderTests \
  2>&1 | grep -E "FAILED|PASSED|passed|error:" | head -10
```

Expected: All tests — old and new — **PASS**. If any new test fails, read the failure message and fix the test (the pipeline is implemented; failures indicate a wrong assertion or struct field name mismatch).

- [ ] **Step 5: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Tests/UnitTests/MessageSenderTests.swift
git commit -m "$(cat <<'EOF'
test: fill sendMedia coverage for image, video, document, and caption paths

Adds four unit tests to MessageSenderTests that verify:
- image/jpeg send roundtrips encryptionKey+IV from upload outcome
- video/mp4 send uses "video" content type string and preserves durationSeconds
- application/pdf send uses "document" type and preserves filename
- caption string is stored in the confirmed attachment's .caption field

Previously only the voice+audio happy path was covered.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Create MediaCaptionView

**Files:**
- Create: `Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift`

This is a standalone SwiftUI view. No dependencies on ViewModel — it takes data in and calls back on confirm/cancel.

- [ ] **Step 1: Create the directory and file**

```bash
mkdir -p /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Chats/Presentation/MediaCaption
```

- [ ] **Step 2: Write `MediaCaptionView.swift`**

```swift
// Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift
import AVKit
import SwiftUI

/// Pre-send media preview screen. Shows the image or video full-screen with a
/// caption text field at the bottom. Tapping Send calls `onSend` with the
/// trimmed caption (or nil if left empty). Tapping the ✕ calls `onCancel`.
struct MediaCaptionView: View {

    // MARK: - Types

    /// The media to preview. Image data is held in memory (photos are typically
    /// < 5 MB at JPEG quality). Video is referenced by file URL to avoid
    /// duplicating large buffers.
    enum Preview: Sendable {
        case image(Data)
        case video(URL)
    }

    // MARK: - Inputs

    let preview: Preview
    let onCancel: () -> Void
    /// Called when the user taps Send. `caption` is nil if the field was left empty.
    let onSend: (_ caption: String?) -> Void

    // MARK: - State

    @State private var caption: String = ""
    @FocusState private var captionFocused: Bool

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            // Dim the bottom third so text is readable over media
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            bottomBar
        }
        .overlay(alignment: .topLeading) { cancelButton }
        .statusBarHidden(true)
        .onAppear { captionFocused = true }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var previewContent: some View {
        switch preview {
        case .image(let data):
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                // Fallback: corrupted/unsupported image data
                Image(systemName: "photo")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.4))
            }

        case .video(let url):
            VideoPlayer(player: AVPlayer(url: url))
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Add a caption…", text: $caption, axis: .vertical)
                .lineLimit(1...4)
                .foregroundColor(.white)
                .tint(.white)
                .focused($captionFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 20))

            Button(action: handleSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
        .padding(.top, 12)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 12)
        .accessibilityLabel("Cancel")
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        onSend(trimmed.isEmpty ? nil : trimmed)
    }
}
```

- [ ] **Step 3: Add the file to the Xcode project**

Find the `project.pbxproj` file group for `Features/Chats/Presentation/` and add the new file. The safest approach is to use the Xcode project file directly:

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS

# Find the pbxproj
ls *.xcodeproj/project.pbxproj

# Verify the new file exists on disk
ls Features/Chats/Presentation/MediaCaption/
```

Add the file to the project's main target in `project.pbxproj`. Look for the `PBXBuildFile` and `PBXFileReference` sections and add entries matching the pattern used by adjacent files in `Features/Chats/Presentation/`. Also add a `PBXGroup` child entry for the `MediaCaption` directory.

Alternatively, open Xcode and drag the file into the navigator — but via script, add the UUID entries manually to match the established pattern.

- [ ] **Step 4: Build to verify compilation**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build succeeded" | head -10
```

Expected: `Build succeeded`.

---

### Task 3: Wire caption screen into ChatDetailView

**Files:**
- Modify: `Features/Chats/Presentation/ChatDetailView.swift`

**Before editing:** Read `ChatDetailView.swift` lines 1–50 (state declarations), lines 1310–1390 (the image/video send handlers), and identify all `viewModel.sendMediaMessage(... caption: nil ...)` call sites that handle image and video picks from the photo library and camera. There will be two: one for video (around line 1354) and one for image (around line 1378). The voice and document send paths skip the caption screen (voice messages don't have captions; files have filenames).

- [ ] **Step 1: Read the current state declarations (lines 1–50)**

Confirm the exact list of `@State` variables. You will add one new one.

- [ ] **Step 2: Read lines 1310–1390 to see the exact send call sites**

Find the exact code that calls `sendMediaMessage(caption: nil)` for the video branch and for the image branch. You will replace those two calls.

- [ ] **Step 3: Add `PendingMediaSend` struct and state variable**

In `ChatDetailView.swift`, BEFORE the `ChatDetailView: View` struct (or just after the import block), add:

```swift
/// Carries the data needed to show the pre-send caption screen for a photo or video.
/// Conforms to Identifiable so it can drive a .fullScreenCover(item:).
private struct PendingMediaSend: Identifiable {
    let id = UUID()
    /// The media content to show in the preview.
    let preview: MediaCaptionView.Preview
    /// Local file URL passed to the upload pipeline.
    let localFileURL: URL
    /// MIME type (e.g. "image/jpeg", "video/mp4").
    let mimeType: String
    /// Pre-built MessageContent enum (url/key fields are placeholders — upload fills them in).
    let contentType: Message.MessageContent
}
```

Inside `ChatDetailView`, in the `@State` block at the top, add:

```swift
@State private var pendingMediaSend: PendingMediaSend? = nil
```

- [ ] **Step 4: Replace the video send call with caption screen presentation**

Find (approximately line 1354):
```swift
            await viewModel.sendMediaMessage(
                localFileURL: tempURL,
                mimeType: "video/mp4",
                contentType: .video(attachment),
                conversationId: conversation.id,
                caption: nil,
                sessionService: container.sessionService,
                messageSender: container.messageSender
            )
```

Replace with:
```swift
            // Show caption screen before sending — user can optionally add a caption.
            await MainActor.run {
                pendingMediaSend = PendingMediaSend(
                    preview: .video(tempURL),
                    localFileURL: tempURL,
                    mimeType: "video/mp4",
                    contentType: .video(attachment)
                )
            }
```

- [ ] **Step 5: Replace the image send call with caption screen presentation**

Find (approximately line 1378):
```swift
            await viewModel.sendMediaMessage(
                localFileURL: tempURL,
                mimeType: "image/jpeg",
                contentType: .image(attachment),
                conversationId: conversation.id,
                caption: nil,
                sessionService: container.sessionService,
                messageSender: container.messageSender
            )
```

Replace with:
```swift
            // Show caption screen before sending — user can optionally add a caption.
            pendingMediaSend = PendingMediaSend(
                preview: .image(imageData),
                localFileURL: tempURL,
                mimeType: "image/jpeg",
                contentType: .image(attachment)
            )
```

Note: `imageData` is already in scope (loaded earlier in this branch).

- [ ] **Step 6: Add the `.fullScreenCover` modifier**

In the `body` of `ChatDetailView`, find the existing modifier chain (look for where other `.sheet` or `.fullScreenCover` modifiers are applied — typically at the end of the view body). Add:

```swift
.fullScreenCover(item: $pendingMediaSend) { payload in
    MediaCaptionView(preview: payload.preview) { caption in
        pendingMediaSend = nil
        Task {
            await viewModel.sendMediaMessage(
                localFileURL: payload.localFileURL,
                mimeType: payload.mimeType,
                contentType: payload.contentType,
                conversationId: conversation.id,
                caption: caption,
                sessionService: container.sessionService,
                messageSender: container.messageSender
            )
        }
    } onCancel: {
        pendingMediaSend = nil
    }
}
```

- [ ] **Step 7: Read back the modified sections to confirm edits applied**

Re-read lines 1310–1390 and the body modifier section. Confirm:
- Both old `sendMediaMessage(caption: nil)` image/video calls are gone
- Two `pendingMediaSend = PendingMediaSend(...)` assignments are in place
- `.fullScreenCover(item: $pendingMediaSend)` modifier is present in the body

- [ ] **Step 8: Build**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build succeeded" | head -10
```

Expected: `Build succeeded`.

- [ ] **Step 9: Run full test suite to confirm no regressions**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "FAILED|passed|failed" | tail -5
```

Expected: Same pass count (273+), 0 new failures.

---

### Task 4: Commit

- [ ] **Step 1: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add \
  Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift \
  Features/Chats/Presentation/ChatDetailView.swift \
  Sanchr.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat: pre-send caption screen for image and video messages

Adds MediaCaptionView — a full-screen Signal-style preview that appears
after a user picks a photo or video. The user can optionally type a caption
before sending. Caption is forwarded to the existing sendMedia pipeline and
stored in the MediaAttachment.caption field so the receiver displays it
below the image.

Document and voice sends are unaffected (no caption screen — filenames
serve as labels for documents; voice messages don't support captions).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- ✅ Pre-send caption entry screen for photos (image picker + camera)
- ✅ Pre-send caption entry screen for videos
- ✅ Caption forwarded to `sendMedia` and stored in attachment
- ✅ Document/voice send unchanged (caption screen not shown)
- ✅ Tests: image key round-trip, video content type, document content type + filename, caption storage
- ✅ Cancel path: `pendingMediaSend = nil` dismisses without sending

**Known gaps (out of scope):**
- AttachmentPickerHost's `.capturedMedia` (camera) path — if this routes through `ChatDetailViewModel.send(intent:)` rather than the inline PhotosPicker handler, it may also need the caption screen. The implementer should search `ChatDetailView.swift` for ALL `sendMediaMessage(caption: nil)` call sites for `.image` and `.video` content and apply the same intercept pattern to each one.
- Captions for images picked from the vault reshare path — out of scope.
- `@State private var pendingMediaSend` is not `@Sendable` — if the PhotosPicker handler runs on a background task, the assignment must be wrapped in `await MainActor.run { }`. The implementer should check whether the existing handler's Task is already on MainActor.
