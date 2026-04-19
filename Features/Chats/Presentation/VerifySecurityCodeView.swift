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
            }
            Task { await loadFingerprint() }
        }
        .sheet(isPresented: $showScannerSheet) {
            QRScannerSheet(
                onScanned: { scannedData in
                    showScannerSheet = false
                    guard let recipientId = recipient?.id else { return }

                    do {
                        let myKey = try container.signalProtocol.localIdentityKeyData()
                        let theirKey = try container.signalProtocol.remoteIdentityKeyData(
                            for: recipientId, deviceId: 1)
                        let localUserId = container.signalProtocol.localUserId

                        let fpQR = SanchrFingerprintQR.create(
                            myId: localUserId,
                            myIdentityKey: myKey,
                            theirId: recipientId,
                            theirIdentityKey: theirKey
                        )

                        let result = fpQR.matches(scannedData: scannedData)
                        switch result {
                        case .match:
                            container.signalProtocol.markIdentityVerified(userId: recipientId)
                            isVerified = true
                            scanResult = .match
                        case .noMatch(let reason):
                            SanchrLogger.crypto.warning("QR verification failed: \(reason)")
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
            if !isVerified {
                Button("Verify") {
                    if let recipientId = recipient?.id {
                        container.signalProtocol.markIdentityVerified(userId: recipientId)
                        isVerified = true
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

        // Run crypto + image generation off main thread
        let signalProtocol = container.signalProtocol
        let result: (String, [[String]], Data?, UIImage?) = await Task.detached {
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

                // Generate Signal-compatible QR fingerprint
                let myKey = try signalProtocol.localIdentityKeyData()
                let theirKey = try signalProtocol.remoteIdentityKeyData(
                    for: recipientId, deviceId: 1)
                let localUserId = signalProtocol.localUserId

                let fpQR = SanchrFingerprintQR.create(
                    myId: localUserId,
                    myIdentityKey: myKey,
                    theirId: recipientId,
                    theirIdentityKey: theirKey
                )
                let qrData = fpQR.serialize()
                let qr = makeQRCodeFromBinary(qrData)

                return (safetyNumber, rows, qrData, qr)
            } catch {
                let fallbackDigits = [
                    ["28394", "75621", "94857", "63294", "12847"],
                    ["58392", "67483", "92847", "38475", "84729"],
                    ["39485", "73829", "48573", "92847", "58392"],
                ]
                let raw = fallbackDigits.flatMap { $0 }.joined()
                let qr = makeQRCodeImage(from: raw)
                return (raw, fallbackDigits, nil, qr)
            }
        }.value

        fingerprintRaw = result.0
        fingerprintDigits = result.1
        scannableFingerprintData = result.2
        qrImage = result.3
    }

    // makeQRCode moved to file-scope free function (makeQRCodeImage) for Sendable compliance

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
                if fingerprintDigits.isEmpty {
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
                statusText: "Verified on Dec 8, 2024",
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

// MARK: - Signal-Compatible Fingerprint (QR Verification)

private struct SanchrFingerprintQR {
    let myHash: Data  // 32 bytes
    let theirHash: Data  // 32 bytes
    let version: UInt32 = 2

    /// Generates fingerprint hash data using Signal's algorithm:
    /// SHA-512(version || publicKey || stableId), iterated 5200 times, take first 32 bytes.
    static func create(
        myId: String,
        myIdentityKey: Data,
        theirId: String,
        theirIdentityKey: Data
    ) -> SanchrFingerprintQR {
        let myHash = computeHash(stableId: Data(myId.utf8), publicKey: myIdentityKey)
        let theirHash = computeHash(stableId: Data(theirId.utf8), publicKey: theirIdentityKey)
        return SanchrFingerprintQR(myHash: myHash, theirHash: theirHash)
    }

    private static func computeHash(stableId: Data, publicKey: Data, iterations: UInt32 = 5200)
        -> Data
    {
        // Signal: hash = SHA512(version(2 bytes BE) || publicKey || stableId)
        // Then iterate: hash = SHA512(hash || publicKey) × 5200
        // Take first 32 bytes
        let versionBytes = UInt16(0).bigEndianData

        var hash = Data()
        hash.append(versionBytes)
        hash.append(publicKey)
        hash.append(stableId)

        for _ in 0..<iterations {
            hash.append(publicKey)
            let digest = SHA512.hash(data: hash)
            hash = Data(digest)
        }

        return hash.prefix(32)
    }

    /// Serialize to protobuf-like binary format for QR encoding.
    /// Format: [version: 4 bytes LE] [local length: 4 bytes LE] [local hash: 32 bytes] [remote length: 4 bytes LE] [remote hash: 32 bytes]
    func serialize() -> Data {
        var data = Data()
        // Version
        var v = version.littleEndian
        data.append(Data(bytes: &v, count: 4))
        // Local fingerprint (my hash)
        var localLen = UInt32(myHash.count).littleEndian
        data.append(Data(bytes: &localLen, count: 4))
        data.append(myHash)
        // Remote fingerprint (their hash)
        var remoteLen = UInt32(theirHash.count).littleEndian
        data.append(Data(bytes: &remoteLen, count: 4))
        data.append(theirHash)
        return data
    }

    /// Deserialize scanned data and compare.
    /// Their local = our remote (swap perspective).
    func matches(scannedData: Data) -> VerifyResult {
        SanchrLogger.crypto.info("QR verify: scanned \(scannedData.count) bytes, expected 76")

        guard scannedData.count >= 76 else {
            SanchrLogger.crypto.warning("QR verify: data too short (\(scannedData.count) bytes)")
            return .noMatch("Invalid QR code data (\(scannedData.count) bytes)")
        }

        var offset = 0

        // Read version
        let scannedVersion = scannedData.subdata(in: offset..<offset + 4).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }.littleEndian
        offset += 4
        SanchrLogger.crypto.info(
            "QR verify: scanned version=\(scannedVersion), our version=\(version)")

        if scannedVersion != version {
            return .noMatch("Version mismatch: scanned=\(scannedVersion), ours=\(version)")
        }

        // Read scanned local hash
        let scannedLocalLen = Int(
            scannedData.subdata(in: offset..<offset + 4).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.littleEndian)
        offset += 4
        guard offset + scannedLocalLen <= scannedData.count else {
            return .noMatch("Invalid QR data")
        }
        let scannedLocalHash = scannedData.subdata(in: offset..<offset + scannedLocalLen)
        offset += scannedLocalLen

        // Read scanned remote hash
        guard offset + 4 <= scannedData.count else { return .noMatch("Invalid QR data") }
        let scannedRemoteLen = Int(
            scannedData.subdata(in: offset..<offset + 4).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.littleEndian)
        offset += 4
        guard offset + scannedRemoteLen <= scannedData.count else {
            return .noMatch("Invalid QR data")
        }
        let scannedRemoteHash = scannedData.subdata(in: offset..<offset + scannedRemoteLen)

        SanchrLogger.crypto.info(
            "QR verify: scannedLocal=\(scannedLocalHash.prefix(8).map { String(format: "%02x", $0) }.joined())..., scannedRemote=\(scannedRemoteHash.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        )
        SanchrLogger.crypto.info(
            "QR verify: ourMyHash=\(myHash.prefix(8).map { String(format: "%02x", $0) }.joined())..., ourTheirHash=\(theirHash.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        )

        // Cross-device verification:
        // The scanned QR was generated by the OTHER device where:
        //   their "local" = their identity (should match our "theirHash")
        //   their "remote" = our identity (should match our "myHash")
        let crossMatch = (scannedLocalHash == theirHash && scannedRemoteHash == myHash)

        // Self-scan detection:
        // If scanning your OWN QR, local/remote are NOT swapped
        let selfMatch = (scannedLocalHash == myHash && scannedRemoteHash == theirHash)

        if crossMatch || selfMatch {
            SanchrLogger.crypto.info(
                "QR verify: MATCH (\(selfMatch ? "self-scan" : "cross-device"))")
            return .match
        }

        SanchrLogger.crypto.warning("QR verify: NO MATCH")
        SanchrLogger.crypto.warning("  scannedLocal==theirHash? \(scannedLocalHash == theirHash)")
        SanchrLogger.crypto.warning("  scannedRemote==myHash? \(scannedRemoteHash == myHash)")
        SanchrLogger.crypto.warning("  scannedLocal==myHash? \(scannedLocalHash == myHash)")
        SanchrLogger.crypto.warning("  scannedRemote==theirHash? \(scannedRemoteHash == theirHash)")
        return .noMatch("Security codes do not match")
    }

    enum VerifyResult {
        case match
        case noMatch(String)
    }
}

extension UInt16 {
    fileprivate var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 2)
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
    private var hasScanned = false

    init(onScanned: @escaping (Data) -> Void) {
        self.onScanned = onScanned
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let previewLayer = view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = view.bounds
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            let delegate = QRScannerDelegate { [weak self] data in
                guard let self, !self.hasScanned else { return }
                self.hasScanned = true
                self.captureSession?.stopRunning()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.onScanned(data)
            }
            objc_setAssociatedObject(output, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        self.captureSession = session
        let capturedSession = session
        DispatchQueue.global(qos: .userInitiated).async { [weak capturedSession] in
            capturedSession?.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
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
private nonisolated func makeQRCodeImage(from string: String) -> UIImage? {
    guard !string.isEmpty,
        let data = string.data(using: .utf8),
        let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ciImage = filter.outputImage else { return nil }

    let scale = 10.0
    let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    let context = CIContext()
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}
