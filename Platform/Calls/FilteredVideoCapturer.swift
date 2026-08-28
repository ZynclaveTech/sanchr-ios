@preconcurrency import AVFoundation
import CoreImage
import UIKit
@preconcurrency import WebRTC

/// Drop-in replacement for `RTCCameraVideoCapturer` that applies a `VideoFilter`
/// to each camera frame before handing it to `RTCVideoSource`.
///
/// ## Thread safety
/// - `currentFilter` (and its backing `_currentFilter`/`_cachedCIFilter`) are guarded by `NSLock`.
///   Written from the main thread via `setVideoFilter(_:)`, read from `captureQueue`.
/// - `captureSession`, `ciContext`, `pixelBufferPool`, `poolWidth`, `poolHeight` are
///   accessed exclusively from `captureQueue` (serial). No additional synchronisation needed.
/// - These constraints justify `@unchecked Sendable`.
final class FilteredVideoCapturer: RTCVideoCapturer, @unchecked Sendable {

    private let lock = NSLock()
    private var _currentFilter: VideoFilter = .none
    private var _cachedCIFilter: CIFilter? = nil

    /// Device orientation and camera position, used to tag every frame with the
    /// rotation the far end must apply.
    ///
    /// The camera sensor delivers landscape buffers whatever way the phone is
    /// held, and the capture connection is deliberately left un-rotated so the
    /// pixel buffers stay in their native layout — rotating them here would
    /// cost a copy per frame. WebRTC instead carries the rotation as metadata
    /// on each frame. `RTCCameraVideoCapturer` does this for you; this class
    /// replaced it to apply filters and reported `._0` for every frame, which
    /// is why a portrait call arrived sideways.
    ///
    /// Written on the main thread from the orientation notification, read on
    /// `captureQueue` per frame, so both go through `lock`.
    private var _deviceOrientation: UIDeviceOrientation = .portrait
    private var _isFrontCamera = true

    var currentFilter: VideoFilter {
        get { lock.withLock { _currentFilter } }
        set {
            lock.withLock {
                _currentFilter = newValue
                _cachedCIFilter = newValue.makeCIFilter()
            }
        }
    }

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "io.sanchr.filteredCapture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Accessed only from captureQueue
    private var pixelBufferPool: CVPixelBufferPool?
    // Accessed only from captureQueue
    private var poolWidth = 0
    // Accessed only from captureQueue
    private var poolHeight = 0

    init(delegate videoSource: RTCVideoSource) {
        super.init(delegate: videoSource)
        observeDeviceOrientation()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor in UIDevice.current.endGeneratingDeviceOrientationNotifications() }
    }

    private func observeDeviceOrientation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            self.storeOrientation(UIDevice.current.orientation)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.deviceOrientationDidChange),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
        }
    }

    @MainActor
    @objc private func deviceOrientationDidChange() {
        storeOrientation(UIDevice.current.orientation)
    }

    /// Face-up, face-down and unknown carry no usable rotation, so the last
    /// real orientation is kept rather than snapping the video to portrait
    /// every time the phone is laid on a table.
    private func storeOrientation(_ orientation: UIDeviceOrientation) {
        guard orientation.isPortrait || orientation.isLandscape else { return }
        lock.withLock { _deviceOrientation = orientation }
    }

    /// Mirrors `RTCCameraVideoCapturer`'s mapping. The two landscape cases
    /// differ by camera because the front sensor is mounted the other way up.
    private func currentRotation() -> RTCVideoRotation {
        let (orientation, isFront) = lock.withLock { (_deviceOrientation, _isFrontCamera) }
        return Self.rotation(for: orientation, isFrontCamera: isFront)
    }

    static func rotation(
        for orientation: UIDeviceOrientation,
        isFrontCamera: Bool
    ) -> RTCVideoRotation {
        switch orientation {
        case .portrait:
            return ._90
        case .portraitUpsideDown:
            return ._270
        case .landscapeLeft:
            return isFrontCamera ? ._180 : ._0
        case .landscapeRight:
            return isFrontCamera ? ._0 : ._180
        default:
            // Face-up, face-down and unknown: portrait is the sane default,
            // and a real orientation is never overwritten by these anyway.
            return ._90
        }
    }

    func startCapture(with device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        lock.withLock { _isFrontCamera = device.position == .front }
        captureQueue.async { [weak self] in
            self?.configureSession(device: device, format: format, fps: fps)
            self?.captureSession.startRunning()
        }
    }

    func stopCapture() {
        captureQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    private func configureSession(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            captureSession.commitConfiguration()
            return
        }
        if captureSession.canAddInput(input) { captureSession.addInput(input) }

        // Apply the format the caller selected
        if device.activeFormat != format {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
            } catch {
                // Continue with device's current format if lock fails
            }
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(output) { captureSession.addOutput(output) }

        captureSession.commitConfiguration()

        // Set frame rate on the device after committing session config
        do {
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            // Frame rate stays at device default; capture continues
        }
    }

    // Must be called from captureQueue
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

extension FilteredVideoCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tsNs = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        lock.lock()
        let ciFilter = _cachedCIFilter
        lock.unlock()

        let rotation = currentRotation()

        // Fast path — no filter, no allocation
        guard let ciFilter else {
            let frame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                rotation: rotation,
                timeStampNs: tsNs
            )
            delegate?.capturer(self, didCapture: frame)
            return
        }

        // Filtered path
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        ciFilter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let outputImage = ciFilter.outputImage else { return }

        ensurePixelBufferPool(width: width, height: height)
        guard let pool = pixelBufferPool else { return }

        var destBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destBuffer)
        guard let destBuffer else { return }

        ciContext.render(outputImage, to: destBuffer)

        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: destBuffer),
            rotation: rotation,
            timeStampNs: tsNs
        )
        delegate?.capturer(self, didCapture: frame)
    }
}
