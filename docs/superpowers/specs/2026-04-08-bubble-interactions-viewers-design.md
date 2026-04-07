# Bubble Interactions & Rich Media Viewers — Design Spec

**Date:** 2026-04-08
**Status:** Approved for planning
**Scope:** iOS client only. No backend changes. No proto changes.

## 1. Problem

Message bubbles in Sanchr today are inert. A user can send and receive images, videos, audio, documents, contacts, and locations, but tapping any of those bubbles does nothing. There is a stub `MediaViewerView` that accepts a single pre-decoded `UIImage` with basic pinch-zoom, but it is not wired to any cell and it does not support pan, paging, video, or any other content type. This spec specifies the full tap-to-open behavior for every rich-content bubble type, plus the viewers themselves.

## 2. Goals

1. Every rich-content bubble is tappable and opens a type-appropriate viewer.
2. The image/video viewer feels on par with WhatsApp and Telegram: pinch-zoom, pan, double-tap-to-zoom, page swipe across all media in the current chat, swipe-down-to-dismiss, PiP for video.
3. Contact, location, and document bubbles provide the full set of sensible actions the user would expect in 2026 (message on Sanchr, invite, save, call, open in Apple/Google Maps, QuickLook preview with share).
4. No new metadata leaks to Sanchr servers or to third parties beyond what already happens from normal iOS map / reverse-geocode usage.
5. The tap-dispatch seam is testable from unit tests without spinning up a real `UICollectionView`.

## 3. Non-Goals

- Forward, reply, pin, star, delete-for-everyone actions inside the viewers. Those belong to the context-menu path already in `MessageCollectionViewController`, not the tap path.
- Custom PDF reader, custom video player chrome, custom map tiles.
- Multi-contact vcard rendering. The send path emits one contact per bubble; multi-contact is out of scope.
- In-app document editing.
- Reshuffling the open gallery when new messages arrive mid-session.
- Any server-side changes. This is a pure client feature.

## 4. Architecture

### 4.1 Tap dispatch seam

Cells inside `MessageCollectionViewController` today already have one precedent for forwarding events upward: `onTapReaction: (String) -> Void` (`MessageCollectionViewController.swift:926`). This spec extends the same pattern.

```
Cell tap
  └─► BubbleTapHandler.handleTap(MessageInteraction)        (closure from VC)
        └─► ChatDetailViewModel.route(interaction:)         (switch on kind)
              ├─► .image / .video  → MediaGalleryCoordinator
              ├─► .contact         → ContactActionCoordinator
              ├─► .location        → LocationPreviewCoordinator
              └─► .document        → DocumentPreviewCoordinator
```

**`MessageInteraction` enum** — the only tap payload type flowing up from cells:

```swift
enum MessageInteraction: Sendable, Equatable {
    case openMedia(messageId: String)          // image OR video; gallery disambiguates
    case openContact(name: String, phoneNumber: String)
    case openLocation(latitude: Double, longitude: Double)
    case openDocument(messageId: String)
}
```

The view controller holds one closure `let onBubbleTap: (MessageInteraction) -> Void`. Every cell variant takes that closure (or nothing, for text/audio/system cells) and fires the appropriate case from its own `UITapGestureRecognizer`. The closure is plumbed through exactly like `onTapReaction` today.

### 4.2 Coordinators

Each viewer has a small `@MainActor` `ObservableObject` coordinator. Coordinators live as `@StateObject`s in `ChatDetailView` and drive `.sheet` / `.fullScreenCover` bindings. Keeping them separate rather than one megacoordinator means each viewer is independently testable and the view model doesn't balloon.

```swift
@MainActor final class MediaGalleryCoordinator: ObservableObject {
    @Published var presentation: GalleryPresentation?
    struct GalleryPresentation: Identifiable {
        let id = UUID()
        let items: [GalleryItem]
        let initialIndex: Int
    }
    struct GalleryItem: Identifiable, Equatable {
        let id: String                // messageId
        let kind: Kind                // .image | .video
        let thumbnailURL: URL?        // pre-decrypted thumbnail already in cache
        let blurHash: String?
        let senderDisplayName: String
        let sentAt: Date
        let caption: String?
    }
}

@MainActor final class ContactActionCoordinator: ObservableObject {
    @Published var pendingContact: PendingContact?
    struct PendingContact: Identifiable {
        let id = UUID()
        let name: String
        let phoneNumber: String
        let resolvedSanchrUserId: String?
        let alreadyInDeviceContacts: Bool
    }
}

@MainActor final class LocationPreviewCoordinator: ObservableObject {
    @Published var presentation: LocationPresentation?
    struct LocationPresentation: Identifiable {
        let id = UUID()
        let latitude: Double
        let longitude: Double
    }
}

@MainActor final class DocumentPreviewCoordinator: ObservableObject {
    @Published var presentation: DocumentPresentation?
    @Published var isResolving: Bool = false
    struct DocumentPresentation: Identifiable {
        let id = UUID()
        let fileURL: URL            // decrypted, named correctly for display
        let fallbackTitle: String
    }
}
```

### 4.3 Media resolver

All viewers that need the actual decrypted bytes (gallery, document) go through a new narrow seam on the existing media subsystem:

```swift
// SanchrShared/Media/MediaResolverProtocol.swift (extends existing resolver)
protocol MediaResolverProtocol: Sendable {
    /// Returns a local file URL for the fully-decrypted message attachment.
    /// If the file is not in cache, downloads and decrypts it, persists it
    /// under `mediaCacheURL/full/<mediaId>/<displayFilename>`, and returns
    /// the URL. The file lives under its original filename (not the mediaId)
    /// so QuickLook and AVFoundation surface the user-facing name.
    func fullFileURL(for messageId: String) async throws -> URL
}
```

Cache layout:

```
<AppGroup mediaCacheURL>/
  full/
    <mediaId>/
      <original-filename-or-mediaId.ext>     # one file per mediaId
```

One directory per mediaId so the original filename can live inside it without collisions. Cache eviction is LRU by directory mtime; the existing media cache eviction job gets extended to include this subtree. First-tap latency is bounded by download + decrypt + one `FileManager.moveItem` — same cost the inline thumbnail path already pays for the small variant.

### 4.4 Gallery seeding

When `.openMedia(messageId)` fires, the view model does **not** hit the DB. `ChatDetailViewModel` already holds an in-memory snapshot of the rendered chat (the same one that drives the collection view). We filter that snapshot for `.image` and `.video` messages, sort chronologically, locate the tapped message, and hand the resulting `[GalleryItem]` plus the initial index to the coordinator. The snapshot is frozen at open time — new messages arriving mid-session do not reshuffle the pager (would move pages under the user's finger).

## 5. Viewer specifications

### 5.1 Media gallery (`MediaGalleryView`)

**Container**

- SwiftUI `TabView(selection: $currentIndex)` with `.tabViewStyle(.page(indexDisplayMode: .never))`. Page-style TabView gives horizontal swipe between media items for free.
- Background: `Color.black.ignoresSafeArea()`. The whole thing is presented as a `.fullScreenCover` so the status bar recolors to light content.
- Header chrome: sender display name + "sent \(relativeDate)" + close X + overflow `⋯`. Fades in/out on single tap with a 0.2s ease.
- Overflow menu: **Save to Photos**, **Share**, **Copy**. (Forward is out of scope per §3.)
- **Dismiss gesture:** swipe-down-to-dismiss on the current page via a `DragGesture` that translates the page and fades the background alpha `1.0 → 0.0` as the drag progresses. Commit the dismiss when either `translation.y > 120` or `velocity.y > 800`. Reversible — releasing early springs back. Disabled while a video's native controls are visible so `AVPlayerViewController` owns drag events in that mode.

**Image page (`GalleryImageView`)**

`ScrollView` is not used. Instead, a custom `UIViewRepresentable` wraps a `UIScrollView` + `UIImageView` — this is the only reliable way in iOS 17+ to get simultaneous pinch-zoom, pan, double-tap-to-zoom, and centered content when zoomed below fill. The implementation mirrors the standard recipe:

```swift
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    init() {
        super.init(frame: .zero)
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        delegate = self
        addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
        let doubleTap = UITapGestureRecognizer(
            target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()   // recenter content when zoomed-out below fill
    }
    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = gr.location(in: imageView)
            let rect = zoomRect(for: 3, center: point)
            zoom(to: rect, animated: true)
        }
    }
}
```

Placeholder chain: blurHash → already-cached thumbnail → full decrypted image. Loading spinner if the full image isn't resolved yet. Full-image decode happens on a background actor so swiping into a not-yet-decoded page doesn't stutter.

**Video page (`GalleryVideoView`)**

`VideoPlayer` is not used (SwiftUI's built-in wrapper hides too much of AVPlayerViewController's behavior). Instead, a `UIViewControllerRepresentable` wraps `AVPlayerViewController` directly:

```swift
struct AVPlayerVCView: UIViewControllerRepresentable {
    let url: URL
    @Binding var isActive: Bool   // becomes false when paged away
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if !isActive { vc.player?.pause() }
    }
}
```

Native chrome gives us scrub bar, skip ±15s, AirPlay, PiP, playback speed, subtitles, chapters, and remote control. The player is created lazily on page appear and torn down on page disappear — swiping away from a video stops playback. PiP is the only state that survives dismissal (standard AV behavior).

**Save to Photos**

- Requires `NSPhotoLibraryAddUsageDescription` — added in §7.
- Uses `PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL:) }` (or `...forVideoAtFileURL:` for video) with `.addOnly` access level — we never need to read the library, only add.
- On success, show a transient toast. On failure (permission denied, disk full), show an alert.

### 5.2 Contact viewer (`ContactActionSheet`)

**Resolution** happens before the sheet is presented so we know which rows to show. Two sources in order:

1. **Sanchr user lookup** — query the local `contacts` table (already populated by `ContactDataSource.syncContacts`). Normalize the incoming phone using the **same** helper that contact sync uses (`ContactDataSource.hashPhoneNumber` / whatever `normalized` implementation it uses internally) so a vcard's `+91 98765 43210` matches a stored `+919876543210`. Using the existing helper is a hard requirement — any divergence silently drops matches for the whole feature. If we find the contact is a Sanchr user, we have a `resolvedSanchrUserId`.
2. **Device contact match** — silent `CNContactStore.enumerateContacts` filtered by phone. Sets `alreadyInDeviceContacts`. Already covered by the existing `NSContactsUsageDescription`.

Neither lookup hits the network. No metadata leaves the device from opening a contact bubble.

**Layout**

Presented as a `.sheet` with `.presentationDetents([.medium])`:

- Top card: avatar (Sanchr avatar if registered, else a generic SF Symbol), name, phone.
- Vertical list of actions:

| Row | Shown when | Action |
|---|---|---|
| **Message on Sanchr** | `resolvedSanchrUserId != nil` AND userId ≠ current user | Dismiss → pop current chat if needed → push `ChatDetailView` via existing `OpenOrCreateConversationUseCase` |
| **Invite to Sanchr** | `resolvedSanchrUserId == nil` | Present `UIActivityViewController` prefilled with the standard invite link + body |
| **Save to Contacts** | `!alreadyInDeviceContacts` | Present `CNContactViewController(forNewContact:)` prefilled with name + phone |
| **View in Contacts** | `alreadyInDeviceContacts` | Present `CNContactViewController(for:)` read-only |
| **Call** | always | `UIApplication.shared.open(URL("tel://\(phone)"))` |
| **Send SMS** | always | `UIApplication.shared.open(URL("sms://\(phone)"))` |
| **Copy number** | always | `UIPasteboard.general.string = phone` + toast |
| **Cancel** | always | Dismiss |

**Self-contact edge case:** if the received contact resolves to the current user's own Sanchr id, hide both "Message on Sanchr" and "Invite" — only Save / View / Call / SMS / Copy remain.

**Stale contact sync:** if a phone is actually a Sanchr user but our local contacts table hasn't sync'd yet, we fall back to "not a Sanchr user". Acceptable — same staleness as the contacts tab. We do **not** run a background re-sync on tap: the added latency and the server-visible timing signal (see `metadata_privacy_plan.md`) aren't worth it.

**"Message on Sanchr" navigation:** reuses the existing `OpenOrCreateConversationUseCase` that `ContactsListView` already calls. If we're currently in a chat and the target is the same chat partner, we no-op dismiss (don't restack the same chat). If it's a different partner, we pop the current chat first so chats don't stack in the nav (WhatsApp behavior).

### 5.3 Location viewer (`LocationPreviewView`)

**Presentation:** `.fullScreenCover`. Three zones stacked vertically.

**Top bar** — back/close, coordinates as `lat.4f°, lon.4f°` in secondary color, share button top-right.

**Map** — `Map(position: $cameraPosition)` (SwiftUI MapKit, iOS 17+) with one `Marker` pinned at the coordinate. Initial camera: `MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)`. Interactive: pinch zoom, two-finger rotate, pan. **`showsUserLocation = false` — the receiver's own blue dot is never rendered.** This is defense against accidental screenshot leaks of the viewer's own position, not a real attack vector, but free to add.

**Bottom floating card** — rounded, semi-transparent, anchored above safe area:

- Place name from reverse geocoding (primary text, if available)
- Coordinates (secondary text, always)
- "Directions" primary button

**Reverse geocoding** happens once on appear via `CLGeocoder.reverseGeocodeLocation`, cached in `@State`, failure is silent (card falls back to coordinates only). Cancelled on disappear. This call sends the coordinate to Apple's servers along with the device IP — same threat model as the inline MapKit tile fetches and as reverse-geocoding anywhere else on iOS. **Not sent if the user never opens the viewer.**

**Action sheet** triggered by either the share button or the Directions button (same sheet — the answer is identical either way):

- **Open in Apple Maps** — `MKMapItem(placemark: MKPlacemark(coordinate:)).openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])`
- **Open in Google Maps** — `comgooglemaps://?q=\(lat),\(lon)&center=\(lat),\(lon)&zoom=15` if `UIApplication.canOpenURL` succeeds, else fall back to `https://maps.google.com/?q=\(lat),\(lon)` in the in-app browser / Safari
- **Copy Coordinates** — `UIPasteboard.general.string = "\(lat), \(lon)"` + toast
- **Cancel**

### 5.4 Document viewer (`DocumentPreviewView`)

**Flow**

1. `.openDocument(messageId)` fires.
2. `DocumentPreviewCoordinator` sets `isResolving = true`; the chat detail view shows a lightweight progress overlay.
3. Coordinator calls `MediaResolverProtocol.fullFileURL(for: messageId)`. This both downloads+decrypts if necessary and returns a URL whose last path component is the original filename (see §4.3 cache layout).
4. Coordinator sets `presentation = DocumentPresentation(fileURL:, fallbackTitle:)` and `isResolving = false`.
5. A `.fullScreenCover` bound to `presentation` presents a `UIViewControllerRepresentable` wrapping `QLPreviewController`:

```swift
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                                previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
```

**Filename fidelity**

QuickLook uses the URL's last path component as the display title. Because the cache layout stores files as `full/<mediaId>/<original-filename>`, a PDF arrives in QuickLook showing `Invoice Q4.pdf` instead of a UUID. `MediaAttachment.filename` already propagates through the upload path; the resolver is the one place we honor it.

**Unsupported formats**

If `QLPreviewController.canPreview(url as NSURL)` returns false (proprietary formats, corrupted files), the coordinator instead presents `UIDocumentInteractionController.presentOptionsMenu` so the user at least gets "Open In…" to hand off to another app. No dead end.

**What QuickLook gives us for free**

- PDF (multi-page, search, text selection, thumbnails panel)
- Office (doc/docx/xls/xlsx/ppt/pptx)
- Pages/Numbers/Keynote
- Images, plain text, RTF, CSV, Markdown
- Audio and video (we still route those to the gallery; QuickLook is for the `.document` case only)
- ZIP/archive previews
- Built-in share button in the nav bar — Save to Files, Mail, Print, Copy, Open In…

No custom chrome around QuickLook. If a user wants to save a PDF to Files, the native share button already does it.

## 6. Error handling

- **Media resolver failure** (network, decryption, disk full): gallery page shows a retry button over the blurHash placeholder; document coordinator shows an alert and dismisses. Never silently fail.
- **Missing QuickLook support**: fall through to `UIDocumentInteractionController` (§5.4).
- **Google Maps not installed**: fall through to web URL (§5.3).
- **Save-to-Photos permission denied**: alert with a "Open Settings" button (`UIApplication.openSettingsURLString`). Not auto-retried.
- **Reverse geocoding failure**: silent, card falls back to coordinates.
- **Sanchr contact lookup miss**: treat as "not a Sanchr user" (§5.2).
- **Self-contact in received vcard**: hide Message/Invite (§5.2).
- **Empty coordinate / malformed file URL** in the underlying message: cell suppresses the tap gesture entirely. We do not present a viewer for broken data.

## 7. Info.plist additions

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Sanchr saves photos and videos from chats to your library when you tap Save.</string>

<key>LSApplicationQueriesSchemes</key>
<array>
    <string>comgooglemaps</string>
</array>
```

`NSContactsUsageDescription`, `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryUsageDescription`, and `NSLocationWhenInUseUsageDescription` already exist in `project.yml` and don't need changes. No new location permission — we render received coordinates only, we do not read the receiver's position.

## 8. Testing

Unit tests (no UIKit required):

- **`ChatDetailViewModel.route(interaction:)`** — each `MessageInteraction` case routes to the right coordinator and updates the right `@Published` property. Fakes for all four coordinators.
- **Gallery seeding** — given a mixed-content message snapshot and a tapped messageId, the produced `[GalleryItem]` contains only `.image`/`.video` messages in chronological order with the tapped item's index correct.
- **Contact resolution** — given a phone, (a) returns a Sanchr userId when the contacts table has a match, (b) returns nil when it does not, (c) normalizes phone format variations, (d) self-contact is detected.
- **Document filename fidelity** — given a `MediaAttachment.filename = "Invoice Q4.pdf"`, the resolver returns a URL whose last path component equals that string.
- **Media resolver cache hit path** — second call for the same messageId returns immediately without invoking the network fake.

UI-level smoke tests (XCUITest, one each):

- Tap an image bubble → gallery appears → swipe paginates → close dismisses.
- Tap a contact bubble → action sheet appears → "Copy number" puts the number on the pasteboard.
- Tap a document bubble → QuickLook appears → close returns to chat.
- Tap a location bubble → preview appears → share button opens action sheet.

(Gallery's pinch/pan/double-tap is tested manually; UI tests can't reliably drive pinch gestures.)

## 9. Rollout

Single phase. Everything ships together behind no feature flag — there is no existing viewer to A/B against, and the current "tap does nothing" baseline means there's nothing to break.

## 10. Out of scope / future

- Forward, reply, pin inside viewers (context menu handles these).
- Multi-image select in gallery for batch save/share.
- Custom PDF reader with thumbnails sidebar.
- In-viewer captions editing.
- Video trimming / export.
- Map snapshot images baked into the chat bubble (today the bubble is a placeholder tile; this spec only changes tap behavior, not the bubble itself).

## 11. Open questions

None outstanding. All resolved during brainstorming:

- Paging scope = all media in the chat (Q1)
- Video player = AVPlayerViewController (Q2)
- Contact actions = all four: Message / Invite / Save / Call+SMS+Copy (Q3)
- Location flow = inline MapKit preview → action sheet, `showsUserLocation = false` (Q4, plus privacy hardening)
- Document viewer = QuickLook, fall through to UIDocumentInteractionController for unsupported formats (Q5)
- Architecture = closures from cells → view model → per-type coordinators (§4.1), mirrors existing `onTapReaction` pattern
