@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import CryptoKit
import SanchrShared
import SwiftUI
import UIKit

// MARK: - VerifySecurityCodeView
// Extracted from ConversationInfoView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct VerifySecurityCodeView: View {
    let conversation: Conversation
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedFingerprint = false
    @State private var fingerprintDigits: [[String]] = []
    @State private var verifiedAt: Date?
    @State private var fingerprintRaw: String = ""
    @State private var qrImage: UIImage?
    @State private var scannableFingerprintData: Data?
    @State private var loadError: String?
    @State private var isVerified = false
    @State private var showVerifiedAlert = false
    @State private var showScannerSheet = false
    @State private var scanResult: ScanResultType?

    enum ScanResultType {
        case match
        case mismatch
        case error(String)
    }

    private var recipient: User? {
        conversation.participants.first(where: { !$0.isLocalUser })
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                mainContent
            }
            .background(SanchrExportColors.background.ignoresSafeArea())

            verifyFooter
        }
        .navigationTitle("Encryption Keys")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let recipientId = recipient?.id {
                isVerified = container.signalProtocol.isIdentityVerified(userId: recipientId)
                verifiedAt = container.signalProtocol.identityVerifiedAt(userId: recipientId)
            }
            Task { await loadFingerprint() }
        }
        .sheet(isPresented: $showScannerSheet) {
            QRScannerSheet(
                onScanned: { scannedData in
                    showScannerSheet = false
                    guard let recipientId = recipient?.id else { return }

                    do {
                        // libsignal's own comparison. The previous hand-rolled
                        // parser used a different version constant and iteration
                        // structure from the digits shown above, hand-parsed the
                        // frame with unaligned loads on attacker-supplied bytes,
                        // and — most seriously — treated scanning your own code as
                        // a successful match, so a user could verify a contact
                        // without ever seeing that contact's device.
                        let matched = try container.signalProtocol.compareFingerprint(
                            scannedData, for: recipientId, deviceId: 1)
                        if matched {
                            container.signalProtocol.markIdentityVerified(userId: recipientId)
                            isVerified = true
                            verifiedAt = container.signalProtocol.identityVerifiedAt(
                                userId: recipientId)
                            scanResult = .match
                        } else {
                            // A mismatch invalidates any earlier verification: the
                            // key in front of us is not the one we trusted.
                            SanchrLogger.crypto.warning("Safety number scan did not match")
                            container.signalProtocol.unmarkIdentityVerified(userId: recipientId)
                            isVerified = false
                            verifiedAt = nil
                            scanResult = .mismatch
                        }
                    } catch {
                        scanResult = .error(error.localizedDescription)
                    }
                },
                onCancel: { showScannerSheet = false }
            )
        }
        .alert(
            scanResultTitle,
            isPresented: Binding(
                get: { scanResult != nil },
                set: { if !$0 { scanResult = nil } }
            )
        ) {
            Button("OK", role: .cancel) { scanResult = nil }
        } message: {
            Text(scanResultMessage)
        }
        .alert(
            isVerified ? "Already Verified" : "Mark as Verified",
            isPresented: $showVerifiedAlert
        ) {
            // Only offer manual confirmation when a real code is on screen. With
            // no digits there is nothing the user could have compared, so the
            // affirmation would be meaningless.
            if !isVerified, !fingerprintDigits.isEmpty {
                Button("Verify") {
                    if let recipientId = recipient?.id {
                        container.signalProtocol.markIdentityVerified(userId: recipientId)
                        isVerified = true
                        verifiedAt = container.signalProtocol.identityVerifiedAt(
                            userId: recipientId)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            if isVerified {
                Text("This contact's identity has already been verified.")
            } else {
                Text("Have you compared security codes with your contact and confirmed they match?")
            }
        }
    }

    private func loadFingerprint() async {
        guard let recipientId = recipient?.id else {
            loadError = "No recipient found"
            return
        }

        // Run crypto + image generation off the main thread.
        //
        // There is deliberately no fallback. This previously substituted a
        // hardcoded set of digits whenever the crypto threw, which meant both
        // devices displayed the same constant, the codes appeared to match, and
        // the user could mark a session verified that had never been checked —
        // the worst possible outcome for the one screen people are told to trust.
        // Failing visibly is the only safe behaviour.
        let signalProtocol = container.signalProtocol
        let outcome: Result<(String, [[String]], Data, UIImage?), Error> = await Task.detached {
            do {
                let safetyNumber = try signalProtocol.safetyNumber(for: recipientId, deviceId: 1)

                let digits = stride(from: 0, to: safetyNumber.count, by: 5).map { i in
                    let start = safetyNumber.index(safetyNumber.startIndex, offsetBy: i)
                    let end = safetyNumber.index(start, offsetBy: min(5, safetyNumber.count - i))
                    return String(safetyNumber[start..<end])
                }
                let rows = stride(from: 0, to: digits.count, by: 5).map { i in
                    Array(digits[i..<min(i + 5, digits.count)])
                }

                // libsignal's own scannable fingerprint. The displayed digits and
                // the QR now come from one generator, so they cannot disagree.
                let qrData = try signalProtocol.scannableFingerprint(
                    for: recipientId, deviceId: 1)
                let qr = makeQRCodeFromBinary(qrData)

                return .success((safetyNumber, rows, qrData, qr))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let (raw, rows, qrData, qr)):
            fingerprintRaw = raw
            fingerprintDigits = rows
            scannableFingerprintData = qrData
            qrImage = qr
            loadError = nil
        case .failure(let error):
            fingerprintRaw = ""
            fingerprintDigits = []
            scannableFingerprintData = nil
            qrImage = nil
            loadError =
                "Couldn't compute this contact's security code. Exchange messages first, then try again."
            SanchrLogger.crypto.error(
                "Safety number unavailable for \(recipientId.prefix(8)): \(error.localizedDescription)"
            )
        }
    }


    /// Real verification state. Previously this card rendered the literal string
    /// "Verified on Dec 8, 2024" unconditionally, telling every user they had
    /// verified every contact on a date that never happened.
    private var verificationStatusText: String {
        guard isVerified else { return "Not verified" }
        guard let verifiedAt else { return "Verified" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Verified on \(formatter.string(from: verifiedAt))"
    }

    private var scanResultTitle: String {
        switch scanResult {
        case .match: return "Verified"
        case .mismatch: return "Not Matched"
        case .error: return "Error"
        case nil: return ""
        }
    }

    private var scanResultMessage: String {
        switch scanResult {
        case .match: return "Security codes match. This conversation is verified and secure."
        case .mismatch: return "Security codes do not match. This may indicate a security issue."
        case .error(let msg): return "Could not verify: \(msg)"
        case nil: return ""
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 32) {
            qrVerificationSection
            fingerprintSection
            encryptionDetailsSection
            infoCard
            Color.clear.frame(height: 80)  // space for fixed footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    // MARK: - QR Verification

    private var qrVerificationSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Verify Security Code")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text(
                    "Compare this QR code with your contact's device or verify the 60-digit code below"
                )
                .font(SanchrTypography.messageBubbleText)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)
            }

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(colorScheme == .dark ? Color(hex: 0x1A1A24) : Color(hex: 0xF9FAFB))
                .frame(height: 280)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? Color(hex: 0x24243A) : Color.white)
                        .frame(width: 220, height: 220)
                        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
                        .overlay {
                            if let qrImage {
                                let img = Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(16)
                                if colorScheme == .dark {
                                    img.colorInvert()
                                } else {
                                    img
                                }
                            } else {
                                ProgressView()
                                    .tint(.sanchrPrimary)
                            }
                        }
                }

            Button {
                showScannerSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Scan QR Code")
                        .font(SanchrTypography.body)
                        .fontWeight(.semibold)
                }
                .foregroundColor(SanchrColors.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(SanchrColors.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Security Fingerprint

    private var fingerprintSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Security Fingerprint")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(SanchrExportColors.textPrimary)
                Spacer()
                Button {
                    let allNumbers = fingerprintDigits.flatMap { $0 }.joined(separator: " ")
                    UIPasteboard.general.string = allNumbers
                    copiedFingerprint = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedFingerprint = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(copiedFingerprint ? "Copied!" : "Copy")
                            .font(SanchrTypography.messageBubbleText)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(SanchrColors.primary)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 12) {
                if let loadError {
                    // Show the failure rather than spinning forever. There is no
                    // safe placeholder here: any digits we invent would appear on
                    // both devices and read as a successful match.
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.orange)
                        Text("Security code unavailable")
                            .font(SanchrTypography.body)
                            .fontWeight(.semibold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(loadError)
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                } else if fingerprintDigits.isEmpty {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    ForEach(0..<fingerprintDigits.count, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<fingerprintDigits[row].count, id: \.self) { col in
                                Text(fingerprintDigits[row][col])
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        colorScheme == .dark ? Color(hex: 0x24243A) : Color.white
                                    )
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .background(colorScheme == .dark ? Color(hex: 0x1A1A24) : Color(hex: 0xF9FAFB))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Encryption Details

    private var encryptionDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Encryption Details")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(SanchrExportColors.textPrimary)

            encryptionDetailCard(
                icon: "key.fill",
                iconBg: SanchrColors.primary.opacity(0.1),
                iconColor: SanchrColors.primary,
                title: "Your Identity Key",
                subtitle: "Your unique encryption key that identifies you in all conversations",
                gradientStart: SanchrColors.primary.opacity(0.05),
                gradientEnd: SanchrColors.accent.opacity(0.05),
                borderColor: SanchrColors.primary.opacity(0.1)
            )

            encryptionDetailCard(
                icon: "lock.fill",
                iconBg: SanchrColors.accent.opacity(0.1),
                iconColor: SanchrColors.accent,
                title: "Session Key",
                subtitle: "Temporary key for this conversation, regenerated periodically",
                gradientStart: SanchrColors.accent.opacity(0.05),
                gradientEnd: SanchrColors.primary.opacity(0.05),
                borderColor: SanchrColors.accent.opacity(0.1)
            )

            encryptionDetailCard(
                icon: "shield.fill",
                iconBg: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.2) : Color(hex: 0xDCFCE7),
                iconColor: Color(hex: 0x16A34A),
                title: "Verification Status",
                subtitle: nil,
                statusText: verificationStatusText,
                gradientStart: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.08) : Color(hex: 0xF0FDF4),
                gradientEnd: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.05) : Color(hex: 0xECFDF5),
                borderColor: colorScheme == .dark
                    ? Color(hex: 0x16A34A).opacity(0.2) : Color(hex: 0xBBF7D0)
            )
        }
    }

    private func encryptionDetailCard(
        icon: String,
        iconBg: Color,
        iconColor: Color,
        title: String,
        subtitle: String?,
        statusText: String? = nil,
        gradientStart: Color,
        gradientEnd: Color,
        borderColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(iconBg)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
                    .foregroundColor(SanchrExportColors.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                if let statusText {
                    Text(statusText)
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.semibold)
                        .foregroundColor(Color(hex: 0x16A34A))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                colorScheme == .dark ? Color(hex: 0x1A1A24) : Color.white
                LinearGradient(
                    colors: [gradientStart, gradientEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(colorScheme == .dark ? borderColor.opacity(0.3) : borderColor, lineWidth: 1)
        }
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(SanchrColors.primary.opacity(0.1))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(SanchrColors.primary)
                }

            Text(
                "If your security code matches your contact's code, your conversation is secure. No one, not even Sanchr, can read your messages."
            )
            .font(SanchrTypography.messageBubbleText)
            .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(20)
        .background(colorScheme == .dark ? Color(hex: 0x1A1A24) : Color(hex: 0xF9FAFB))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Footer

    private var verifyFooter: some View {
        VStack(spacing: 0) {
            Button {
                showVerifiedAlert = true
            } label: {
                SanchrGradientButtonLabel(
                    title: isVerified ? "Verified" : "Mark as Verified",
                    systemName: isVerified ? "checkmark.seal.fill" : "checkmark.shield.fill"
                )
            }
            .buttonStyle(SanchrPrimaryCTA())
            .opacity(isVerified ? 0.7 : 1.0)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(
            SanchrExportColors.background
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - QR Code Scanner

private struct QRScannerSheet: View {
    let onScanned: (Data) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            ZStack {
                QRScannerRepresentable(onScanned: onScanned)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("Point your camera at the QR code on your contact's device")
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.bottom, 60)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (Data) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onScanned: onScanned)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private class QRScannerViewController: UIViewController {
    private let onScanned: (Data) -> Void
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    /// Held here rather than via objc_setAssociatedObject with a String key, which
    /// only worked because of literal interning and left the delegate's lifetime
    /// tied to an output object by accident.
    private var metadataDelegate: QRScannerDelegate?

    /// AVCaptureSession start/stop block. Doing either on the main thread stalls
    /// the UI for as long as the camera takes to spin up or tear down.
    private let sessionQueue = DispatchQueue(label: "io.sanchr.qr-scanner.session")

    init(onScanned: @escaping (Data) -> Void) {
        self.onScanned = onScanned
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureForCurrentAuthorization()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        messageStack?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = captureSession
        sessionQueue.async { session?.stopRunning() }
    }

    // MARK: - Authorization

    /// Decides what the sheet shows. Previously there was no check at all: a
    /// denied permission fell through `try?` and returned silently, leaving the
    /// user staring at a black rectangle with no explanation and no way forward.
    private func configureForCurrentAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startCamera()
                    } else {
                        self.showMessage(
                            title: "Camera access needed",
                            body: "Sanchr needs the camera to scan your contact's security code.",
                            showSettings: true)
                    }
                }
            }
        case .denied, .restricted:
            showMessage(
                title: "Camera access is off",
                body: "Enable camera access for Sanchr to scan your contact's security code. You can still compare the numbers by hand.",
                showSettings: true)
        @unknown default:
            showMessage(
                title: "Camera unavailable",
                body: "The camera could not be used for scanning. Compare the numbers by hand instead.",
                showSettings: false)
        }
    }

    // MARK: - Camera

    private func startCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video) else {
            // Simulators and camera-less devices land here.
            showMessage(
                title: "No camera available",
                body: "This device has no camera. Compare the security code numbers by hand instead.",
                showSettings: false)
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            SanchrLogger.crypto.error(
                "QR scanner input failed: \(error.localizedDescription)")
            showMessage(
                title: "Camera unavailable",
                body: "The camera could not be started. Compare the security code numbers by hand instead.",
                showSettings: false)
            return
        }

        guard session.canAddInput(input) else {
            showMessage(
                title: "Camera unavailable",
                body: "The camera could not be started. Compare the security code numbers by hand instead.",
                showSettings: false)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showMessage(
                title: "Scanning unavailable",
                body: "This device cannot scan QR codes. Compare the security code numbers by hand instead.",
                showSettings: false)
            return
        }
        session.addOutput(output)

        let delegate = QRScannerDelegate { [weak self] data in
            guard let self, !self.hasScanned else { return }
            self.hasScanned = true
            let session = self.captureSession
            self.sessionQueue.async { session?.stopRunning() }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.onScanned(data)
        }
        metadataDelegate = delegate
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        captureSession = session
        sessionQueue.async { session.startRunning() }
    }

    // MARK: - Explanatory state

    private var messageStack: UIView?

    /// Replaces the black rectangle with something that says what happened and,
    /// where it helps, offers a way to fix it.
    private func showMessage(title: String, body: String, showSettings: Bool) {
        messageStack?.removeFromSuperview()

        let container = UIView(frame: view.bounds)
        container.backgroundColor = .black

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
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -32),
        ])

        view.addSubview(container)
        messageStack = container
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private class QRScannerDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let handler: (Data) -> Void

    init(handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject else {
            return
        }

        // Extract raw binary data from QR codewords using Signal's approach
        if #available(iOS 17.0, *),
            let descriptor = object.descriptor as? CIQRCodeDescriptor
        {
            let codewords = descriptor.errorCorrectedPayload
            let version = descriptor.symbolVersion
            if let payload = QRByteModeParser.parse(codewords: codewords, qrVersion: version) {
                SanchrLogger.crypto.info(
                    "QR scan: parsed \(payload.count) bytes from codewords (\(codewords.count) raw)"
                )
                handler(payload)
                return
            }
        }

        // Fallback: use string value with Latin1 to preserve byte values
        if let stringValue = object.stringValue,
            let data = stringValue.data(using: .isoLatin1)
        {
            SanchrLogger.crypto.info("QR scan: fallback Latin1, \(data.count) bytes")
            handler(data)
        }
    }
}

// MARK: - QR Byte-Mode Parser (Signal's QRCodePayload approach)

/// Parses raw QR error-corrected codewords to extract byte-mode payload.
/// CIQRCodeDescriptor.errorCorrectedPayload returns raw codewords which include
/// mode indicators and character count bits -- NOT the actual data bytes.
private enum QRByteModeParser {
    static func parse(codewords: Data, qrVersion: Int) -> Data? {
        var bitOffset = 0
        let bits = codewords.flatMap { byte -> [UInt8] in
            (0..<8).reversed().map { UInt8((byte >> $0) & 1) }
        }

        // Read 4-bit mode indicator
        guard bitOffset + 4 <= bits.count else { return nil }
        let mode = readBits(bits, offset: &bitOffset, count: 4)
        guard mode == 4 else {
            // Mode 4 = Byte mode. Other modes not supported for fingerprint QR.
            SanchrLogger.crypto.warning("QR parse: unsupported mode \(mode)")
            return nil
        }

        // Character count indicator length depends on QR version
        let charCountBits: Int
        if qrVersion <= 9 {
            charCountBits = 8
        } else if qrVersion <= 26 {
            charCountBits = 16
        } else {
            charCountBits = 16
        }

        guard bitOffset + charCountBits <= bits.count else { return nil }
        let charCount = Int(readBits(bits, offset: &bitOffset, count: charCountBits))
        guard charCount > 0 else { return nil }

        // Read the actual data bytes
        var result = Data(capacity: charCount)
        for _ in 0..<charCount {
            guard bitOffset + 8 <= bits.count else { return nil }
            let byte = UInt8(readBits(bits, offset: &bitOffset, count: 8))
            result.append(byte)
        }

        return result
    }

    private static func readBits(_ bits: [UInt8], offset: inout Int, count: Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<count {
            value = (value << 1) | UInt32(bits[offset])
            offset += 1
        }
        return value
    }
}

// MARK: - QR Code Generation (nonisolated, Sendable-safe)

/// Generates a QR code from raw binary data (Signal ScannableFingerprint).
private nonisolated func makeQRCodeFromBinary(_ data: Data) -> UIImage? {
    guard !data.isEmpty,
        let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("L", forKey: "inputCorrectionLevel")
    guard let ciImage = filter.outputImage else { return nil }

    let scale = 10.0
    let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}

/// Generates a QR code from a string (fallback for safety number digits).
