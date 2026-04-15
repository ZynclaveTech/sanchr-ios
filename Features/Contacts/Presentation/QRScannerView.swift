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

    private func handleCode(_ code: String) {
        guard !hasScanned else { return }
        guard code.contains("sanchr.io") else {
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
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
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
