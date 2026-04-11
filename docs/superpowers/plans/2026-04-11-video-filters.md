# Video Call Filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real-time video filters (Core Image, GPU-accelerated) to video calls, applied 100% on-device before frames enter the WebRTC pipeline.

**Architecture:** `FilteredVideoCapturer` replaces `RTCCameraVideoCapturer` in `WebRTCClient`. It owns the `AVCaptureSession`, processes each `CMSampleBuffer` through the active `VideoFilter` via `CIContext`, then delivers the filtered frame to `RTCVideoSource`. `CallManager` exposes `setVideoFilter(_:)`. The call UI adds a filter picker row.

**Tech Stack:** `AVFoundation` (`AVCaptureSession`, `AVCaptureVideoDataOutput`), `CoreImage` (`CIFilter`, `CIContext`), `WebRTC` (`RTCVideoSource`, `RTCVideoFrame`, `RTCCVPixelBuffer`), SwiftUI.

---

### Task 1: `VideoFilter` enum

**Files:**
- Create: `ios/Sanchr-iOS/Platform/Calls/VideoFilter.swift`
- Create: `ios/Sanchr-iOS/Tests/UnitTests/Platform/Calls/VideoFilterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UnitTests/Platform/Calls/VideoFilterTests.swift
import XCTest
import CoreImage
@testable import Sanchr

final class VideoFilterTests: XCTestCase {

    func test_allCases_haveNonEmptyDisplayName() {
        for filter in VideoFilter.allCases {
            XCTAssertFalse(filter.displayName.isEmpty,
                "\(filter) has empty displayName")
        }
    }

    func test_none_producesNilCIFilter() {
        XCTAssertNil(VideoFilter.none.makeCIFilter())
    }

    func test_smoothSkin_producesGaussianBlur() {
        let f = VideoFilter.smoothSkin.makeCIFilter()
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.name, "CIGaussianBlur")
    }

    func test_warm_producesTemperatureAndTint() {
        let f = VideoFilter.warm.makeCIFilter()
        XCTAssertEqual(f?.name, "CITemperatureAndTint")
    }

    func test_cool_producesTemperatureAndTint() {
        let f = VideoFilter.cool.makeCIFilter()
        XCTAssertEqual(f?.name, "CITemperatureAndTint")
    }

    func test_blackAndWhite_producesColorMonochrome() {
        let f = VideoFilter.blackAndWhite.makeCIFilter()
        XCTAssertEqual(f?.name, "CIColorMonochrome")
    }

    func test_vivid_producesVibrance() {
        let f = VideoFilter.vivid.makeCIFilter()
        XCTAssertEqual(f?.name, "CIVibrance")
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

```bash
xcodebuild test -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/VideoFilterTests 2>&1 | tail -10
```

Expected: compile error — `VideoFilter` not found.

- [ ] **Step 3: Implement `VideoFilter`**

```swift
// Platform/Calls/VideoFilter.swift
import CoreImage

/// Available real-time video filters for calls.
/// `.none` is the raw camera feed — no processing.
enum VideoFilter: String, CaseIterable, Identifiable, Sendable {
    case none
    case smoothSkin
    case warm
    case cool
    case blackAndWhite
    case vivid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:         return "None"
        case .smoothSkin:   return "Smooth"
        case .warm:         return "Warm"
        case .cool:         return "Cool"
        case .blackAndWhite: return "B&W"
        case .vivid:        return "Vivid"
        }
    }

    /// Returns a configured `CIFilter` for this effect, or `nil` for `.none`.
    func makeCIFilter() -> CIFilter? {
        switch self {
        case .none:
            return nil

        case .smoothSkin:
            let f = CIFilter(name: "CIGaussianBlur")!
            f.setValue(1.5, forKey: kCIInputRadiusKey)
            return f

        case .warm:
            let f = CIFilter(name: "CITemperatureAndTint")!
            f.setValue(CIVector(x: 8000, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            return f

        case .cool:
            let f = CIFilter(name: "CITemperatureAndTint")!
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 8000, y: 0), forKey: "inputTargetNeutral")
            return f

        case .blackAndWhite:
            let f = CIFilter(name: "CIColorMonochrome")!
            f.setValue(CIColor.gray, forKey: kCIInputColorKey)
            f.setValue(1.0, forKey: kCIInputIntensityKey)
            return f

        case .vivid:
            let f = CIFilter(name: "CIVibrance")!
            f.setValue(0.5, forKey: kCIInputAmountKey)
            return f
        }
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
xcodebuild test -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/VideoFilterTests 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: `Test Suite 'VideoFilterTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Platform/Calls/VideoFilter.swift \
        Tests/UnitTests/Platform/Calls/VideoFilterTests.swift
git commit -m "feat: add VideoFilter enum with Core Image filter builders"
```

---

### Task 2: `FilteredVideoCapturer`

**Files:**
- Create: `ios/Sanchr-iOS/Platform/Calls/FilteredVideoCapturer.swift`

This class owns `AVCaptureSession`. It is not unit-tested (requires real hardware/simulator camera session); tested via simulator build verification.

- [ ] **Step 1: Implement `FilteredVideoCapturer`**

```swift
// Platform/Calls/FilteredVideoCapturer.swift
import AVFoundation
import CoreImage
import WebRTC

/// Drop-in replacement for `RTCCameraVideoCapturer` that applies a `VideoFilter`
/// to each camera frame before delivering it to `RTCVideoSource`.
///
/// Thread safety: `currentFilter` is set from the main thread and read from the
/// capture queue — protected via `NSLock`.
final class FilteredVideoCapturer: NSObject, @unchecked Sendable {

    // MARK: - Public state

    /// The filter applied to each frame. Settable at any time during a call.
    var currentFilter: VideoFilter = .none {
        didSet {
            lock.lock()
            _currentFilter = currentFilter
            lock.unlock()
        }
    }

    // MARK: - Private

    private weak var videoSource: RTCVideoSource?

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "io.sanchr.filteredCapture", qos: .userInitiated)
    private var currentDevice: AVCaptureDevice?

    /// `CIContext` is expensive to create; create once and reuse.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// `CVPixelBufferPool` reduces per-frame allocation overhead.
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    private let lock = NSLock()
    private var _currentFilter: VideoFilter = .none

    // MARK: - Init

    init(delegate videoSource: RTCVideoSource) {
        self.videoSource = videoSource
        super.init()
    }

    // MARK: - Capture Control

    /// Starts camera capture using `device`. Call from the main thread.
    func startCapture(with device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        captureQueue.async { [weak self] in
            self?.configureSession(device: device, format: format, fps: fps)
            self?.captureSession.startRunning()
        }
        currentDevice = device
    }

    /// Stops capture and tears down the session.
    func stopCapture() {
        captureQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    // MARK: - Session Setup

    private func configureSession(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        // Remove existing inputs/outputs
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            captureSession.commitConfiguration()
            return
        }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }

        // Set frame rate
        if let connection = output.connection(with: .video) {
            connection.videoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            connection.videoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        }

        captureSession.commitConfiguration()
    }

    // MARK: - Pixel Buffer Pool

    private func ensurePixelBufferPool(width: Int, height: Int) {
        guard width != poolWidth || height != poolHeight else { return }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
        poolWidth = width
        poolHeight = height
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FilteredVideoCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let videoSource,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        lock.lock()
        let activeFilter = _currentFilter
        lock.unlock()

        // Fast path: no filter
        guard let ciFilter = activeFilter.makeCIFilter() else {
            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let frame = RTCVideoFrame(
                buffer: rtcBuffer,
                rotation: ._0,
                timeStampNs: Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)
            )
            videoSource.capturer(nil, didCapture: frame)
            return
        }

        // Filtered path
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        ciFilter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let outputImage = ciFilter.outputImage else { return }

        ensurePixelBufferPool(width: width, height: height)
        guard let pool = pixelBufferPool else { return }

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let destBuffer = outputBuffer else { return }

        ciContext.render(outputImage, to: destBuffer)

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: destBuffer)
        let frame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)
        )
        videoSource.capturer(nil, didCapture: frame)
    }
}
```

- [ ] **Step 2: Build to verify no compile errors**

```bash
xcodebuild build -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep "error:" | head -20
```

- [ ] **Step 3: Commit**

```bash
git add Platform/Calls/FilteredVideoCapturer.swift
git commit -m "feat: add FilteredVideoCapturer — Core Image filter pipeline for WebRTC frames"
```

---

### Task 3: Swap capturer in `WebRTCClient`

**Files:**
- Modify: `ios/Sanchr-iOS/Platform/Calls/WebRTCClient.swift`

Re-read the full `WebRTCClient.swift` before making changes.

- [ ] **Step 1: Change the stored property type**

Line 43 — change:
```swift
private var videoCapturer: RTCCameraVideoCapturer?
```
to:
```swift
private var videoCapturer: FilteredVideoCapturer?
```

- [ ] **Step 2: Update `startLocalMedia` to create `FilteredVideoCapturer`**

In `startLocalMedia(isVideo:)`, replace the `#else` branch (lines 127–129):

```swift
#else
    let capturer = FilteredVideoCapturer(delegate: videoSource)
    self.videoCapturer = capturer
    startCameraCapture(capturer: capturer)
#endif
```

- [ ] **Step 3: Update `startCameraCapture` to accept `FilteredVideoCapturer`**

Re-read the existing `startCameraCapture` signature (look for it below line 200 in the file). Update its parameter type from `RTCCameraVideoCapturer` to `FilteredVideoCapturer` and update the body to use `AVCaptureDevice` directly:

```swift
private func startCameraCapture(capturer: FilteredVideoCapturer) {
    let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    else {
        SanchrLogger.calls.error("No camera found for position \(position.rawValue)")
        return
    }

    guard let format = device.formats.last(where: {
        let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
        return dims.width <= 1280 && dims.height <= 720
    }) ?? device.formats.first else {
        SanchrLogger.calls.error("No suitable format found")
        return
    }

    capturer.startCapture(with: device, format: format, fps: 30)
    SanchrLogger.calls.info("Camera capture started: \(position == .front ? "front" : "back")")
}
```

- [ ] **Step 4: Update `toggleCamera` to use new stop/start API**

`toggleCamera()` currently calls `capturer.stopCapture()` and `startCameraCapture(capturer:)`. The method signatures are the same — no change needed if `FilteredVideoCapturer` implements `stopCapture()` (it does).

- [ ] **Step 5: Update `toggleVideo` to use new stop/start API**

Same — `videoCapturer?.stopCapture()` and `startCameraCapture(capturer:)` work unchanged.

- [ ] **Step 6: Add `setVideoFilter` method**

Add at the end of the `// MARK: - Media` section:

```swift
/// Sets the real-time video filter applied to outgoing frames.
/// Takes effect on the next frame; safe to call during an active call.
func setVideoFilter(_ filter: VideoFilter) {
    videoCapturer?.currentFilter = filter
    SanchrLogger.calls.info("Video filter set to: \(filter.displayName)")
}
```

- [ ] **Step 7: Build to verify**

```bash
xcodebuild build -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep "error:" | head -20
```

- [ ] **Step 8: Commit**

```bash
git add Platform/Calls/WebRTCClient.swift
git commit -m "feat: swap RTCCameraVideoCapturer → FilteredVideoCapturer in WebRTCClient"
```

---

### Task 4: Expose filter in `CallManager`

**Files:**
- Modify: `ios/Sanchr-iOS/Platform/Calls/CallManager.swift`

Re-read `CallManager.swift` before editing.

- [ ] **Step 1: Add `currentVideoFilter` observable property**

In the `// MARK: - Observable State` section, add:

```swift
var currentVideoFilter: VideoFilter = .none
```

- [ ] **Step 2: Add `setVideoFilter` method**

In the `// MARK: - In-Call Controls` section, after `switchCamera()`:

```swift
func setVideoFilter(_ filter: VideoFilter) {
    currentVideoFilter = filter
    webRTCClient.setVideoFilter(filter)
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep "error:" | head -20
```

- [ ] **Step 4: Commit**

```bash
git add Platform/Calls/CallManager.swift
git commit -m "feat: expose setVideoFilter on CallManager"
```

---

### Task 5: Filter picker UI in `ActiveCallView`

**Files:**
- Modify: `ios/Sanchr-iOS/Features/Calls/Presentation/ActiveCallView.swift`

Re-read `ActiveCallView.swift` before editing.

- [ ] **Step 1: Add the filter picker subview**

Add a new private method inside `ActiveCallView` (after `callControls` or `endCallButton`):

```swift
@ViewBuilder
private func filterPicker(callManager: CallManager) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: SanchrSpacing.sm) {
            ForEach(VideoFilter.allCases) { filter in
                Button {
                    callManager.setVideoFilter(filter)
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(
                                    callManager.currentVideoFilter == filter
                                        ? Color.sanchrPrimary
                                        : Color.white.opacity(0.15)
                                )
                                .frame(width: 48, height: 48)
                            Image(systemName: filterIcon(for: filter))
                                .foregroundStyle(.white)
                                .font(.system(size: 18))
                        }
                        Text(filter.displayName)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SanchrSpacing.md)
    }
}

private func filterIcon(for filter: VideoFilter) -> String {
    switch filter {
    case .none:         return "camera"
    case .smoothSkin:   return "sparkles"
    case .warm:         return "sun.max"
    case .cool:         return "snowflake"
    case .blackAndWhite: return "circle.lefthalf.filled"
    case .vivid:        return "paintpalette"
    }
}
```

- [ ] **Step 2: Insert the filter picker into `body`**

In the `body` property, inside the video call `VStack`, add the filter picker between the local video PiP and the call controls. After the `if callManager.isVideoEnabled, case .active` PiP block:

```swift
// Filter picker — visible only during active video call
if callManager.isVideoEnabled, case .active = callManager.callState {
    filterPicker(callManager: callManager)
        .padding(.bottom, SanchrSpacing.sm)
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep "error:" | head -20
```

- [ ] **Step 4: Run all existing tests to confirm no regressions**

```bash
xcodebuild test -scheme Sanchr -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "Test Suite.*passed|Test Suite.*failed|error:" | head -20
```

- [ ] **Step 5: Commit**

```bash
git add Features/Calls/Presentation/ActiveCallView.swift
git commit -m "feat: add video filter picker to ActiveCallView"
```

---

## Self-Review Checklist

- [x] `FilteredVideoCapturer` creates `CIContext` once (not per-frame) ✓
- [x] `CVPixelBufferPool` reused across frames; only recreated on dimension change ✓
- [x] Fast path for `.none` — skips Core Image entirely (no allocation) ✓
- [x] `currentFilter` write from main thread / read from capture queue — protected by `NSLock` ✓
- [x] `filterIcon(for:)` and `filterPicker` are defined inside `ActiveCallView` — no new file needed ✓
- [x] `CallManager.currentVideoFilter` is `@Observable` — UI auto-updates without extra bindings ✓
- [x] No mention of Snap Camera Kit in the implementation — architecture is ready for future Banuba swap without API changes ✓
- [x] No backend changes required — confirmed in spec ✓
