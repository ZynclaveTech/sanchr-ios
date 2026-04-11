# Video Call Filters — Design Spec

**Date:** 2026-04-11
**Status:** Approved for implementation

---

## Overview

Add real-time video filters to Sanchr video calls. Filters are applied entirely on the sender's device — the server never touches video frames. This is a pure client-side feature that requires no backend changes.

---

## Architecture: Where Filters Live

```
Camera → AVCaptureSession
           ↓
      CMSampleBuffer (raw frames)
           ↓
   FilteredVideoCapturer         ← NEW: applies Core Image filter pipeline
           ↓
      RTCVideoSource              ← existing WebRTC source (unchanged interface)
           ↓
   RTCVideoTrack → H.264 encoder → SRTP encrypted → network
```

The integration point is `WebRTCClient.swift:43` where `videoCapturer: RTCCameraVideoCapturer?` currently captures directly to `RTCVideoSource`. `RTCCameraVideoCapturer` will be replaced by a new `FilteredVideoCapturer` that intercepts each `CMSampleBuffer`, optionally applies a Core Image filter, then forwards the (possibly filtered) pixel buffer to `RTCVideoSource`.

---

## Phase 1: Core Image Filters

### Filters Included

| Filter | Core Image Name | Description |
|--------|----------------|-------------|
| None | — | Raw camera (default) |
| Smooth Skin | `CIFilter.gaussianBlur` + luminance mask | Light skin smoothing |
| Warm | `CIFilter.temperatureAndTint` | +200K color temperature |
| Cool | `CIFilter.temperatureAndTint` | -200K color temperature |
| B&W | `CIFilter.colorMonochrome` | Grayscale |
| Vivid | `CIFilter.vibrance` + `CIFilter.colorControls` | Boosted saturation |

All are `CIFilter` operations processed on the GPU via `CIContext(options: [.useSoftwareRenderer: false])`. No pixel data leaves the device.

### `FilteredVideoCapturer`

A new class that:
1. Owns an `AVCaptureSession` (replacing `RTCCameraVideoCapturer`'s session)
2. Implements `AVCaptureVideoDataOutputSampleBufferDelegate`
3. Holds a `currentFilter: VideoFilter` property (settable from the call UI)
4. On each `captureOutput(_:didOutput:)`:
   - If `currentFilter == .none` → forward `CMSampleBuffer` directly to `RTCVideoSource` via `RTCVideoSource.adaptOutputFormat` + `RTCVideoSource.capturer(_:didCapture:)`
   - Otherwise → render through `CIContext`, write to a `CVPixelBuffer`, wrap in `RTCVideoFrame`, deliver to `RTCVideoSource`
5. Conforms to the same start/stop/switch-camera interface as `RTCCameraVideoCapturer` so `WebRTCClient` needs minimal changes

### `VideoFilter` enum

```swift
enum VideoFilter: String, CaseIterable, Identifiable {
    case none
    case smoothSkin
    case warm
    case cool
    case blackAndWhite
    case vivid

    var id: String { rawValue }
    var displayName: String { ... }
}
```

### Performance constraints

- Target: < 5ms per frame at 720p on iPhone 12+
- `CIContext` is created once and reused (creation is expensive)
- Pixel buffer pool via `CVPixelBufferPool` to avoid per-frame allocation
- If a frame takes > 16ms to process, drop it rather than queue (WebRTC tolerates occasional drops)

---

## `WebRTCClient` Changes

`videoCapturer: RTCCameraVideoCapturer?` (line 43) becomes `videoCapturer: FilteredVideoCapturer?`.

`startLocalMedia(isVideo:)` creates a `FilteredVideoCapturer` instead of `RTCCameraVideoCapturer`.

One new method exposed:

```swift
func setVideoFilter(_ filter: VideoFilter)
```

This forwards the filter to `FilteredVideoCapturer.currentFilter`. Can be called at any time during a call; takes effect on the next frame.

---

## Call UI Changes

A filter picker appears as a horizontally scrollable row of thumbnails at the bottom of the video call screen (visible only when local video is active). Tapping a filter calls `setVideoFilter(_:)` via the call view model. The selected filter persists only for the duration of the call — no persistence between calls.

---

## Phase 2: Future Path (not in scope now)

When Snap Camera Kit's analytics policy becomes acceptable for Sanchr, or when custom Metal shaders are warranted:

- `FilteredVideoCapturer` already owns the `CMSampleBuffer` intercept point
- Phase 2 replaces the `CIFilter` pipeline with a `BanubaEffectPlayer` or `MTLCommandBuffer` pipeline inside the same class
- `WebRTCClient` and the call UI require no changes — the filter enum gains new cases

The architecture is designed so that Phase 2 is a drop-in swap of the processing step, not a restructuring.

**Why not Snap Camera Kit:** Camera Kit sends session analytics and lens usage telemetry to Snap's servers. For a privacy-first E2EE messenger this is unacceptable — Snap would learn when users are in video calls and usage patterns. Banuba SDK is the preferred future path as it offers enterprise contracts with configurable/disableable data collection and no mandatory attribution.

---

## What Stays on the Backend

Nothing. No backend changes. The server sees the same encrypted SRTP stream it always has. Filters are invisible to the network.

---

## Files Touched

| File | Change |
|------|--------|
| `Platform/Calls/FilteredVideoCapturer.swift` | New — owns capture session + filter pipeline |
| `Platform/Calls/VideoFilter.swift` | New — `VideoFilter` enum with display names and CI filter builders |
| `Platform/Calls/WebRTCClient.swift` | Change `videoCapturer` type; add `setVideoFilter(_:)` |
| `Features/Calls/.../CallViewModel` (or equivalent) | Expose `VideoFilter` selection to call UI |
| `Features/Calls/.../ActiveCallView` (or equivalent) | Add filter picker row to video call UI |
