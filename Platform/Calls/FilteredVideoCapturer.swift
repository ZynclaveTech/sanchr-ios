import AVFoundation
import CoreImage
@preconcurrency import WebRTC

/// Drop-in replacement for `RTCCameraVideoCapturer` that applies a `VideoFilter`
/// to each camera frame before handing it to `RTCVideoSource`.
///
/// Thread safety: `currentFilter` is written from the main thread and read from
/// the capture queue, guarded by `NSLock`.
final class FilteredVideoCapturer: RTCVideoCapturer, @unchecked Sendable {

    var currentFilter: VideoFilter = .none {
        didSet {
            lock.lock()
            _currentFilter = currentFilter
            lock.unlock()
        }
    }

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "io.sanchr.filteredCapture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private let lock = NSLock()
    private var _currentFilter: VideoFilter = .none

    init(delegate videoSource: RTCVideoSource) {
        super.init(delegate: videoSource)
    }

    func startCapture(with device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
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

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(output) { captureSession.addOutput(output) }

        captureSession.commitConfiguration()

        // Set frame rate on the device after committing session config
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        try? device.lockForConfiguration()
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

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
        let activeFilter = _currentFilter
        lock.unlock()

        // Fast path — no filter, no allocation
        guard let ciFilter = activeFilter.makeCIFilter() else {
            let frame = RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                rotation: ._0,
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
            rotation: ._0,
            timeStampNs: tsNs
        )
        delegate?.capturer(self, didCapture: frame)
    }
}
