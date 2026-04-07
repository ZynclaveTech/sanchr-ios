// AttachmentPickerCameraTile.swift
import UIKit
import AVFoundation

@MainActor
final class CameraTileCell: UICollectionViewCell {

    private let previewContainer = UIView()
    private let cameraIconView = UIImageView()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    // nonisolated(unsafe): AVCaptureSession is thread-safe for start/stop and we
    // gate access through main-actor cell lifecycle + the global userInitiated queue
    // for start/stopRunning. Tradeoff: Swift 6 cannot prove this; we accept the
    // unchecked annotation rather than wrapping in an actor (which would force
    // every UIKit-side access to be async).
    nonisolated(unsafe) private static let sharedSession = AVCaptureSession()
    nonisolated(unsafe) private static var isConfigured = false
    /// True only after configureSessionIfNeeded successfully attached a camera input.
    /// On the simulator (no camera hardware) this stays false and we never call
    /// startRunning — calling it without an input triggers `Fig assert ... err=-17281`.
    nonisolated(unsafe) private static var hasCameraInput = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.clipsToBounds = true
        contentView.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        previewContainer.frame = contentView.bounds
        previewContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(previewContainer)

        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        cameraIconView.image = UIImage(systemName: "camera.fill", withConfiguration: cfg)
        cameraIconView.tintColor = .white
        cameraIconView.contentMode = .center
        cameraIconView.frame = contentView.bounds
        cameraIconView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(cameraIconView)

        startIfAuthorized()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func startIfAuthorized() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else { return }
        Self.configureSessionIfNeeded()
        // No camera hardware (simulator, denied at OS level, etc.) — keep the SF
        // Symbol fallback visible and skip session start to avoid Fig asserts.
        guard Self.hasCameraInput else { return }
        let layer = AVCaptureVideoPreviewLayer(session: Self.sharedSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewContainer.bounds
        previewContainer.layer.addSublayer(layer)
        previewLayer = layer
        cameraIconView.isHidden = true
        if !Self.sharedSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                Self.sharedSession.startRunning()
            }
        }
    }

    private static func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        sharedSession.beginConfiguration()
        sharedSession.sessionPreset = .medium
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           sharedSession.canAddInput(input) {
            sharedSession.addInput(input)
            hasCameraInput = true
        }
        sharedSession.commitConfiguration()
        isConfigured = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = previewContainer.bounds
    }

    static func stopSession() {
        guard hasCameraInput, sharedSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            sharedSession.stopRunning()
        }
    }
}
