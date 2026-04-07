import SanchrShared
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

// NOTE: requires NSCameraUsageDescription in Info.plist

/// Full-screen camera capture used by the attachment picker.
///
/// Owns its own `AVCaptureSession` configured for photo capture, with shutter,
/// cancel and flip-camera controls. All session configuration happens on a
/// dedicated background queue; UI updates are dispatched back to the main
/// queue. The session is torn down in `viewWillDisappear` so the camera LED
/// turns off as soon as the controller leaves the screen.
final class CameraCaptureViewController: UIViewController {

    // MARK: - Callbacks

    nonisolated(unsafe) private let onCapture: (CapturedMedia) -> Void
    nonisolated(unsafe) private let onCancel: () -> Void

    // MARK: - Capture pipeline

    nonisolated private let sessionQueue = DispatchQueue(label: "com.sanchr.camera.session")
    nonisolated private let session = AVCaptureSession()
    nonisolated private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private var currentInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var currentPosition: AVCaptureDevice.Position = .back

    // MARK: - UI

    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    private lazy var previewContainer: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var cancelButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Cancel", for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
        return b
    }()

    private lazy var flipButton: UIButton = {
        let b = UIButton(type: .system)
        let img = UIImage(systemName: "arrow.triangle.2.circlepath")
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(handleFlip), for: .touchUpInside)
        return b
    }()

    private lazy var shutterButton: UIButton = {
        let b = UIButton(type: .custom)
        b.backgroundColor = .white
        b.layer.cornerRadius = 36
        b.layer.borderColor = UIColor.white.cgColor
        b.layer.borderWidth = 4
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(handleShutter), for: .touchUpInside)
        return b
    }()

    private lazy var shutterRing: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        v.layer.borderWidth = 3
        v.layer.cornerRadius = 44
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    // MARK: - Init

    init(
        onCapture: @escaping (CapturedMedia) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutUI()
        requestAccessAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = previewContainer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - Layout

    private func layoutUI() {
        view.addSubview(previewContainer)
        previewContainer.layer.addSublayer(previewLayer)
        view.addSubview(cancelButton)
        view.addSubview(flipButton)
        view.addSubview(shutterRing)
        view.addSubview(shutterButton)

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),

            flipButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            flipButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            flipButton.widthAnchor.constraint(equalToConstant: 44),
            flipButton.heightAnchor.constraint(equalToConstant: 44),

            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            shutterButton.widthAnchor.constraint(equalToConstant: 72),
            shutterButton.heightAnchor.constraint(equalToConstant: 72),

            shutterRing.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
            shutterRing.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            shutterRing.widthAnchor.constraint(equalToConstant: 88),
            shutterRing.heightAnchor.constraint(equalToConstant: 88),
        ])
    }

    // MARK: - Permissions + Configuration

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in self?.configureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.sessionQueue.async { self.configureSession() }
                } else {
                    Task { @MainActor in self.presentDeniedAlert() }
                }
            }
        case .denied, .restricted:
            presentDeniedAlert()
        @unknown default:
            presentDeniedAlert()
        }
    }

    nonisolated private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Replace existing input if any (used by flip).
        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }

        guard
            let device = bestCamera(for: currentPosition),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            Task { @MainActor [weak self] in self?.presentDeniedAlert() }
            return
        }
        session.addInput(input)
        currentInput = input

        if session.canAddOutput(photoOutput), !session.outputs.contains(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()

        if !session.isRunning {
            session.startRunning()
        }
    }

    nonisolated private func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return dev
        }
        return AVCaptureDevice.default(for: .video)
    }

    private func presentDeniedAlert() {
        let alert = UIAlertController(
            title: "Camera Access Needed",
            message: "Enable camera access in Settings to capture photos.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { [weak self] _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            self?.handleCancel()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.handleCancel()
        })
        present(alert, animated: true)
    }

    // MARK: - Actions

    @objc private func handleCancel() {
        onCancel()
    }

    @objc private func handleFlip() {
        currentPosition = (currentPosition == .back) ? .front : .back
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    @objc private func handleShutter() {
        let settings = AVCapturePhotoSettings()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraCaptureViewController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard
            error == nil,
            let data = photo.fileDataRepresentation()
        else {
            return
        }

        var width = 0
        var height = 0
        if let image = UIImage(data: data) {
            width = Int(image.size.width * image.scale)
            height = Int(image.size.height * image.scale)
        }

        let captured = CapturedMedia(
            kind: .photo,
            data: data,
            capturedAt: Date(),
            width: width,
            height: height,
            durationSeconds: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.onCapture(captured)
        }
    }
}

// MARK: - SwiftUI bridge

struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (CapturedMedia) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CameraCaptureViewController {
        CameraCaptureViewController(onCapture: onCapture, onCancel: onCancel)
    }

    func updateUIViewController(_ uiViewController: CameraCaptureViewController, context: Context) {
        // Stateless — closures are captured at init time.
    }
}
