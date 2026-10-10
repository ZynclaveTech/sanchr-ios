import AVFoundation
import SwiftUI
import SanchrShared

struct QRScannerView: View {
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasScanned = false

    var body: some View {
        ZStack {
            QRCameraPreview(onCodeFound: handleCode)
                .ignoresSafeArea()

            // Dark overlay with transparent viewfinder cutout
            ViewfinderOverlay()
                .ignoresSafeArea()

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                    .padding(.trailing, SanchrSpacing.lg)
                    .padding(.top, SanchrSpacing.mega)
                }
                Spacer()
            }

            // Instructional label
            VStack {
                Spacer()
                Text("Align QR code within the frame")
                    .font(SanchrTypography.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, SanchrSpacing.xl)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                    .padding(.bottom, SanchrSpacing.mega)
            }
        }
        .statusBarHidden()
    }

    /// Whether [code] is a `https://sanchr.com/...` link — the shape
    /// `ProfileView` encodes (`https://sanchr.com/u/{userId}`).
    static func isSanchrContactCode(_ code: String) -> Bool {
        guard let url = URL(string: code.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased()
        else { return false }
        return host == "sanchr.com" || host.hasSuffix(".sanchr.com")
    }

    private func handleCode(_ code: String) {
        guard !hasScanned else { return }
        // Host, not substring: `contains("sanchr.com")` matched anywhere in the
        // payload, so `https://evil.example/?x=sanchr.com` passed the check.
        guard Self.isSanchrContactCode(code) else {
            SanchrLogger.contacts.debug("Ignored non-Sanchr QR code")
            return
        }
        hasScanned = true

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        onScanned(code)
    }
}

// MARK: - Viewfinder Overlay

private struct ViewfinderOverlay: View {
    private let cutoutSize: CGFloat = 250
    private let cornerLength: CGFloat = 30
    private let cornerLineWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(
                x: (geometry.size.width - cutoutSize) / 2,
                y: (geometry.size.height - cutoutSize) / 2,
                width: cutoutSize,
                height: cutoutSize
            )

            ZStack {
                // Semi-transparent dark overlay with cutout
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .mask {
                        Rectangle()
                            .overlay {
                                RoundedRectangle(cornerRadius: SanchrRadius.lg)
                                    .frame(width: cutoutSize, height: cutoutSize)
                                    .blendMode(.destinationOut)
                            }
                    }

                // Indigo corner brackets
                cornerBrackets(in: rect)
            }
        }
    }

    private func cornerBrackets(in rect: CGRect) -> some View {
        let color = SanchrColors.primary

        return ZStack {
            // Top-left
            CornerBracket(corner: .topLeft, length: cornerLength, lineWidth: cornerLineWidth)
                .stroke(color, lineWidth: cornerLineWidth)
                .frame(width: cutoutSize, height: cutoutSize)
                .position(x: rect.midX, y: rect.midY)

            // Top-right
            CornerBracket(corner: .topRight, length: cornerLength, lineWidth: cornerLineWidth)
                .stroke(color, lineWidth: cornerLineWidth)
                .frame(width: cutoutSize, height: cutoutSize)
                .position(x: rect.midX, y: rect.midY)

            // Bottom-left
            CornerBracket(corner: .bottomLeft, length: cornerLength, lineWidth: cornerLineWidth)
                .stroke(color, lineWidth: cornerLineWidth)
                .frame(width: cutoutSize, height: cutoutSize)
                .position(x: rect.midX, y: rect.midY)

            // Bottom-right
            CornerBracket(corner: .bottomRight, length: cornerLength, lineWidth: cornerLineWidth)
                .stroke(color, lineWidth: cornerLineWidth)
                .frame(width: cutoutSize, height: cutoutSize)
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

// MARK: - Corner Bracket Shape

private enum Corner {
    case topLeft, topRight, bottomLeft, bottomRight
}

private struct CornerBracket: Shape {
    let corner: Corner
    let length: CGFloat
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let offset = lineWidth / 2

        switch corner {
        case .topLeft:
            path.move(to: CGPoint(x: offset, y: length))
            path.addLine(to: CGPoint(x: offset, y: offset))
            path.addLine(to: CGPoint(x: length, y: offset))
        case .topRight:
            path.move(to: CGPoint(x: rect.maxX - length, y: offset))
            path.addLine(to: CGPoint(x: rect.maxX - offset, y: offset))
            path.addLine(to: CGPoint(x: rect.maxX - offset, y: length))
        case .bottomLeft:
            path.move(to: CGPoint(x: offset, y: rect.maxY - length))
            path.addLine(to: CGPoint(x: offset, y: rect.maxY - offset))
            path.addLine(to: CGPoint(x: length, y: rect.maxY - offset))
        case .bottomRight:
            path.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY - offset))
            path.addLine(to: CGPoint(x: rect.maxX - offset, y: rect.maxY - offset))
            path.addLine(to: CGPoint(x: rect.maxX - offset, y: rect.maxY - length))
        }

        return path
    }
}

// MARK: - Camera Preview (UIViewControllerRepresentable)

private struct QRCameraPreview: UIViewControllerRepresentable {
    let onCodeFound: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraViewController {
        let controller = QRCameraViewController()
        controller.onCodeFound = onCodeFound
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCameraViewController, context: Context) {}
}

private final class QRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeFound: ((String) -> Void)?

    private nonisolated(unsafe) let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureForCurrentAuthorization()
    }

    // MARK: - Authorization

    /// Decides what the sheet shows.
    ///
    /// There was no check at all: a denied or not-yet-asked permission fell
    /// through `try?` in `setupCamera` and returned silently, leaving the user
    /// looking at a black rectangle with viewfinder brackets forever, with no
    /// explanation and no way forward. The same bug was found and fixed in the
    /// security-code scanner; this copy was missed.
    private func configureForCurrentAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.setupCamera()
                        self.startSessionIfNeeded()
                    } else {
                        self.showMessage(
                            title: "Camera access needed",
                            body: "Sanchr needs the camera to scan a contact's QR code.",
                            showSettings: true)
                    }
                }
            }
        case .denied, .restricted:
            showMessage(
                title: "Camera access is off",
                body: "Enable camera access for Sanchr to scan a contact's QR code. You can still add them by phone number.",
                showSettings: true)
        @unknown default:
            showMessage(
                title: "Camera unavailable",
                body: "The camera could not be used for scanning. Add the contact by phone number instead.",
                showSettings: false)
        }
    }

    private func startSessionIfNeeded() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    // MARK: - Explanatory state

    private var messageStack: UIView?

    /// Replaces the black rectangle with something that says what happened and,
    /// where it helps, offers a way to fix it.
    private func showMessage(title: String, body: String, showSettings: Bool) {
        messageStack?.removeFromSuperview()

        let container = UIView(frame: view.bounds)
        container.backgroundColor = .black
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "video.slash.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = .preferredFont(forTextStyle: .footnote)
        bodyLabel.textColor = .white.withAlphaComponent(0.75)
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(bodyLabel)

        if showSettings {
            let button = UIButton(type: .system)
            button.setTitle("Open Settings", for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
        ])

        view.addSubview(container)
        messageStack = container
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Only once an input has actually been added: starting a session with
        // no input logs an error every time the sheet appears without the
        // permission.
        guard !captureSession.inputs.isEmpty else { return }
        startSessionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            SanchrLogger.contacts.error("QR scanner: camera unavailable")
            showMessage(
                title: "No camera available",
                body: "This device has no usable camera. Add the contact by phone number instead.",
                showSettings: false)
            return
        }

        guard captureSession.canAddInput(input) else { return }
        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)

        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        messageStack?.removeFromSuperview()
        messageStack = nil
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let value = metadataObject.stringValue
        else { return }

        MainActor.assumeIsolated {
            onCodeFound?(value)
        }
    }
}
