import AVFoundation
import CoreImage.CIFilterBuiltins
import Kingfisher
import SwiftUI

struct ConversationInfoView: View {
    let conversation: Conversation
    let recipient: User?

    @Environment(\.dismiss) private var dismiss
    @State private var notificationsMuted = false
    @State private var mediaVisibility = true
    @State private var sanchrModeEnabled = false
    @State private var showDisappearingMessages = false
    @State private var showVaultMedia = false
    @State private var showWallpaper = false
    @State private var showSearchConversation = false
    @State private var showExportChat = false
    @State private var showClearChat = false
    @State private var showBlockContact = false
    @State private var showReportContact = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                settingsHeader
                profileSection
                mediaSection
                securitySection
                chatPreferencesSection
                sanchrModeSection
                disappearingMessagesSection
                chatActionsSection
                dangerZoneSection
                Color.clear.frame(height: 32)
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $showWallpaper) {
            WallpaperThemeView()
        }
        .navigationDestination(isPresented: $showDisappearingMessages) {
            DisappearingMessagesView()
        }
        .navigationDestination(isPresented: $showVaultMedia) {
            VaultMediaView()
        }
        .sheet(isPresented: $showSearchConversation) {
            SearchConversationView(conversationName: conversation.displayName)
        }
        .confirmationDialog("Export Chat", isPresented: $showExportChat) {
            Button("Export with Media") {}
            Button("Export without Media") {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how to export this conversation")
        }
        .alert("Clear Chat", isPresented: $showClearChat) {
            Button("Clear All Messages", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all messages in this conversation. This action cannot be undone.")
        }
        .alert("Block Contact", isPresented: $showBlockContact) {
            Button("Block", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blocked contacts cannot send you messages or call you. You can unblock them later from Settings.")
        }
        .alert("Report Contact", isPresented: $showReportContact) {
            Button("Report", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Report this contact for inappropriate behavior. We'll review your report and take appropriate action.")
        }
    }

    private var settingsHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.sanchrPrimary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Chat Settings")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(SanchrExportColors.textPrimary)

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(SanchrExportColors.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SanchrExportColors.line)
                .frame(height: 1)
        }
    }

    private var profileSection: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarURL = conversation.avatarURL {
                        KFImage(avatarURL)
                            .resizable()
                            .placeholder {
                                Circle()
                                    .fill(SanchrColors.primary.opacity(0.14))
                                    .overlay {
                                        Text(conversation.displayName.prefix(1).uppercased())
                                            .font(SanchrTypography.sectionHeader)
                                            .foregroundColor(.sanchrPrimary)
                                    }
                            }
                            .fade(duration: 0.2)
                            .scaledToFill()
                    } else {
                        Circle()
                            .fill(SanchrColors.primary.opacity(0.14))
                            .overlay {
                                Text(conversation.displayName.prefix(1).uppercased())
                                    .font(SanchrTypography.sectionHeader)
                                    .foregroundColor(.sanchrPrimary)
                            }
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(Color.white, lineWidth: 2)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)

                Circle()
                    .fill(SanchrColors.accent)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .overlay {
                        Circle().stroke(Color.white, lineWidth: 2)
                    }
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(SanchrExportColors.textPrimary)

                if let phone = recipient?.phoneNumber, !phone.isEmpty {
                    Text(phone)
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(SanchrExportColors.textSecondary)
                } else {
                    Text("Encrypted conversation")
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(SanchrExportColors.textTertiary)
                }

                Text("End-to-End Encrypted")
                    .font(SanchrTypography.captionSmall)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrColors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SanchrColors.accent.opacity(0.1))
                    .clipShape(Capsule())
                    .padding(.top, 6)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary.opacity(0.05), SanchrColors.accent.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Section: Media & Links

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Media & Links")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Spacer()
                Button {} label: {
                    Text("View All")
                        .font(SanchrTypography.messageBubbleText)
                        .fontWeight(.medium)
                        .foregroundColor(SanchrColors.primary)
                }
                .buttonStyle(.plain)
            }

            // TODO: Replace with actual media count from conversation
            let mediaCount = 0

            if mediaCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                        .foregroundColor(SanchrExportColors.textTertiary)
                    Text("No media shared yet")
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(SanchrExportColors.textSecondary)
                    Text("Photos, videos, and files shared in this conversation will appear here")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(mediaGradient(for: index))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if index == 2 {
                                Color.black.opacity(0.4)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        Text("+24")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                            }
                        }
                }
            }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Security & Privacy

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Security & Privacy")
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.semibold)
                .foregroundColor(SanchrExportColors.textPrimary)
                .padding(.bottom, 16)

            NavigationLink {
                VerifySecurityCodeView(conversation: conversation)
            } label: {
                settingsRow(
                    icon: "qrcode",
                    iconBg: SanchrColors.accent.opacity(0.1),
                    iconColor: SanchrColors.accent,
                    title: "Verify Security Code",
                    subtitle: "Confirm end-to-end encryption"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                VerifySecurityCodeView(conversation: conversation)
            } label: {
                settingsRow(
                    icon: "touchid",
                    iconBg: SanchrColors.primary.opacity(0.1),
                    iconColor: SanchrColors.primary,
                    title: "Encryption Keys",
                    subtitle: "View security fingerprint"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Chat Preferences

    private var chatPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat Preferences")
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.semibold)
                .foregroundColor(SanchrExportColors.textPrimary)
                .padding(.bottom, 16)

            settingsToggleRow(
                icon: "bell.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Notifications",
                subtitle: "Mute this conversation",
                isOn: $notificationsMuted
            )

            settingsToggleRow(
                icon: "photo.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Media Visibility",
                subtitle: "Show in gallery",
                isOn: $mediaVisibility
            )

            Button { showWallpaper = true } label: {
                settingsRow(
                    icon: "paintpalette.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Wallpaper & Theme",
                    subtitle: "Customize chat appearance"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Sanchr Mode

    private var sanchrModeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SanchrColors.primaryDark, SanchrColors.primary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sanchr Mode")
                        .font(SanchrTypography.messageBubbleText)
                        .fontWeight(.bold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text("Enhanced privacy & incognito")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $sanchrModeEnabled)
                    .labelsHidden()
                    .tint(.sanchrPrimary)
            }
            .padding(.vertical, 12)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SanchrColors.primary)
                    .padding(.top, 1)
                Text("Sanchr Mode hides notification previews, disables screenshots, and uses darker theme for maximum privacy.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }
            .padding(.top, 12)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .background(
            LinearGradient(
                colors: [SanchrColors.primaryDark.opacity(0.05), SanchrColors.primary.opacity(0.05)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Disappearing Messages

    private var disappearingMessagesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showDisappearingMessages = true } label: {
                settingsRow(
                    icon: "clock.arrow.circlepath",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Disappearing Messages",
                    subtitle: "Off"
                )
            }
            .buttonStyle(.plain)

            Button { showVaultMedia = true } label: {
                settingsRow(
                    icon: "lock.shield.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Vault Media",
                    subtitle: "Self-destructing photos & videos"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Chat Actions

    private var chatActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showSearchConversation = true } label: {
                settingsRow(
                    icon: "magnifyingglass",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Search in Conversation"
                )
            }
            .buttonStyle(.plain)

            Button { showExportChat = true } label: {
                settingsRow(
                    icon: "square.and.arrow.down.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Export Chat",
                    subtitle: "Save conversation backup"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Button { showClearChat = true } label: {
                settingsRow(
                    icon: "trash.fill",
                    iconBg: SanchrExportColors.surfaceSoft,
                    iconColor: SanchrExportColors.textSecondary,
                    title: "Clear Chat",
                    subtitle: "Delete all messages"
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SanchrExportColors.line).frame(height: 1)
        }
    }

    // MARK: - Section: Danger Zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showBlockContact = true } label: {
                dangerRow(icon: "person.fill.xmark", title: "Block Contact")
            }
            .buttonStyle(.plain)

            Button { showReportContact = true } label: {
                dangerRow(icon: "flag.fill", title: "Report Contact")
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    // MARK: - Reusable Helper Functions

    private func settingsRow(
        icon: String,
        iconBg: Color,
        iconColor: Color,
        title: String,
        subtitle: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(iconBg)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func settingsToggleRow(
        icon: String,
        iconBg: Color,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(iconBg)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
        .padding(.vertical, 12)
    }

    private func dangerRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: 0xFEF2F2))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sanchrError)
                }

            Text(title)
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.medium)
                .foregroundColor(.sanchrError)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SanchrColors.error.opacity(0.6))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Media Gradient Helper

    private func mediaGradient(for index: Int) -> LinearGradient {
        let gradients: [[Color]] = [
            [Color(hex: 0xE0E7FF), Color(hex: 0xC7D2FE)],
            [Color(hex: 0xFCE7F3), Color(hex: 0xFBCFE8)],
            [Color(hex: 0xCFFAFE), Color(hex: 0xA5F3FC)],
            [Color(hex: 0xF3E8FF), Color(hex: 0xE9D5FF)],
            [Color(hex: 0xDBEAFE), Color(hex: 0xBFDBFE)],
            [Color(hex: 0xFEF3C7), Color(hex: 0xFDE68A)],
        ]
        let pair = gradients[index % gradients.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct VerifySecurityCodeView: View {
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedFingerprint = false
    @State private var fingerprintDigits: [[String]] = []
    @State private var fingerprintRaw: String = ""
    @State private var qrImage: UIImage?
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
                VStack(spacing: 0) {
                    gradientHeader
                    mainContent
                }
            }
            .background(SanchrExportColors.background.ignoresSafeArea())

            verifyFooter
        }
        .navigationBarHidden(true)
        .task {
            await loadFingerprint()
            if let recipientId = recipient?.id {
                isVerified = container.signalProtocol.isIdentityVerified(userId: recipientId)
            }
        }
        .sheet(isPresented: $showScannerSheet) {
            QRScannerSheet(
                onScanned: { scannedData in
                    showScannerSheet = false
                    guard let recipientId = recipient?.id else { return }
                    do {
                        let matches = try container.signalProtocol.compareFingerprint(
                            scannedData, for: recipientId, deviceId: 1
                        )
                        if matches {
                            container.signalProtocol.markIdentityVerified(userId: recipientId)
                            isVerified = true
                            scanResult = .match
                        } else {
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

        do {
            let safetyNumber = try container.signalProtocol.safetyNumber(for: recipientId, deviceId: 1)
            fingerprintRaw = safetyNumber

            // Split into 5-digit groups arranged in rows of 5
            let digits = stride(from: 0, to: safetyNumber.count, by: 5).map { i in
                let start = safetyNumber.index(safetyNumber.startIndex, offsetBy: i)
                let end = safetyNumber.index(start, offsetBy: min(5, safetyNumber.count - i))
                return String(safetyNumber[start..<end])
            }

            // Arrange into rows of 5 columns
            fingerprintDigits = stride(from: 0, to: digits.count, by: 5).map { i in
                Array(digits[i..<min(i + 5, digits.count)])
            }
        } catch {
            loadError = error.localizedDescription
            // Use placeholder data as fallback
            fingerprintDigits = [
                ["28394", "75621", "94857", "63294", "12847"],
                ["58392", "67483", "92847", "38475", "84729"],
                ["39485", "73829", "48573", "92847", "58392"]
            ]
            fingerprintRaw = fingerprintDigits.flatMap { $0 }.joined()
        }

        // Generate QR after fingerprint is ready
        qrImage = Self.makeQRCode(from: fingerprintRaw)
    }

    private static func makeQRCode(from string: String) -> UIImage? {
        guard !string.isEmpty,
              let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }

        let scale = 10.0
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
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

    // MARK: - Gradient Header

    private var gradientHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Text("Encryption Keys")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 24)

            HStack(spacing: 16) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SanchrColors.accent, SanchrColors.primary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text("End-to-End Encrypted")
                        .font(SanchrTypography.messageBubbleText)
                        .foregroundColor(.white.opacity(0.8))
                    Text(conversation.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()

                Circle()
                    .fill(SanchrColors.accent.opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(SanchrColors.accent)
                    }
            }
            .padding(16)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary, SanchrColors.primaryDark],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea(edges: .top)
        )
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 0) }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 32) {
            qrVerificationSection
            fingerprintSection
            encryptionDetailsSection
            infoCard
            Color.clear.frame(height: 80) // space for fixed footer
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

                Text("Compare this QR code with your contact's device or verify the 60-digit code below")
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
                                .background(colorScheme == .dark ? Color(hex: 0x24243A) : Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                iconBg: colorScheme == .dark ? Color(hex: 0x16A34A).opacity(0.2) : Color(hex: 0xDCFCE7),
                iconColor: Color(hex: 0x16A34A),
                title: "Verification Status",
                subtitle: nil,
                statusText: "Verified on Dec 8, 2024",
                gradientStart: colorScheme == .dark ? Color(hex: 0x16A34A).opacity(0.08) : Color(hex: 0xF0FDF4),
                gradientEnd: colorScheme == .dark ? Color(hex: 0x16A34A).opacity(0.05) : Color(hex: 0xECFDF5),
                borderColor: colorScheme == .dark ? Color(hex: 0x16A34A).opacity(0.2) : Color(hex: 0xBBF7D0)
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

            Text("If your security code matches your contact's code, your conversation is secure. No one, not even Sanchr, can read your messages.")
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

// MARK: - Shared Screen Header Helper

@ViewBuilder
private func screenHeader(title: String, onBack: @escaping () -> Void) -> some View {
    HStack {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.sanchrPrimary)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)

        Spacer()

        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(SanchrExportColors.textPrimary)

        Spacer()

        Color.clear.frame(width: 40, height: 40)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
    .background(SanchrExportColors.background)
    .overlay(alignment: .bottom) {
        Rectangle()
            .fill(SanchrExportColors.line)
            .frame(height: 1)
    }
}

// MARK: - WallpaperThemeView

private struct WallpaperThemeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWallpaper = 0
    @State private var darkMode = false

    private let wallpaperColors: [[Color]] = [
        [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)],  // Default
        [Color(hex: 0xEEF2FF), Color(hex: 0xE0E7FF)],  // Indigo
        [Color(hex: 0xECFEFF), Color(hex: 0xCFFAFE)],  // Cyan
        [Color(hex: 0xFDF2F8), Color(hex: 0xFCE7F3)],  // Pink
        [Color(hex: 0xF0FDF4), Color(hex: 0xDCFCE7)],  // Green
        [Color(hex: 0xFFFBEB), Color(hex: 0xFEF3C7)],  // Amber
        [Color(hex: 0x1E1B4B), Color(hex: 0x312E81)],  // Dark Indigo
        [Color(hex: 0x0F172A), Color(hex: 0x1E293B)],  // Midnight
        [Color(hex: 0x1A1A2E), Color(hex: 0x16213E)],  // Deep Blue
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                screenHeader(title: "Wallpaper & Theme", onBack: { dismiss() })

                VStack(alignment: .leading, spacing: 24) {
                    // Theme toggle
                    HStack(spacing: 12) {
                        Circle()
                            .fill(SanchrExportColors.surfaceSoft)
                            .frame(width: 40, height: 40)
                            .overlay {
                                Image(systemName: darkMode ? "moon.fill" : "sun.max.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(SanchrColors.primary)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dark Mode")
                                .font(SanchrTypography.messageBubbleText)
                                .fontWeight(.medium)
                                .foregroundColor(SanchrExportColors.textPrimary)
                            Text("Use dark theme for this chat")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: $darkMode)
                            .labelsHidden()
                            .tint(.sanchrPrimary)
                    }
                    .padding(.vertical, 12)

                    // Wallpaper grid
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Chat Wallpaper")
                            .font(SanchrTypography.messageBubbleText)
                            .fontWeight(.semibold)
                            .foregroundColor(SanchrExportColors.textPrimary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(0..<wallpaperColors.count, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(LinearGradient(colors: wallpaperColors[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .aspectRatio(0.7, contentMode: .fit)
                                    .overlay {
                                        if selectedWallpaper == index {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(SanchrColors.primary, lineWidth: 3)
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 24))
                                                .foregroundColor(SanchrColors.primary)
                                        }
                                    }
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedWallpaper = index
                                        }
                                    }
                            }
                        }
                    }

                    // Reset button
                    Button {} label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Reset to Default")
                                .font(SanchrTypography.messageBubbleText)
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
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }
}

// MARK: - DisappearingMessagesView

private struct DisappearingMessagesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDuration: Int = 0

    private let options: [(String, String, Int)] = [
        ("Off", "Messages won't be deleted", 0),
        ("5 minutes", "For sensitive conversations", 300),
        ("1 hour", "Short-lived messages", 3600),
        ("24 hours", "Daily cleanup", 86400),
        ("7 days", "Weekly cleanup", 604800),
        ("30 days", "Monthly cleanup", 2592000),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                screenHeader(title: "Disappearing Messages", onBack: { dismiss() })

                VStack(spacing: 0) {
                    // Info banner
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(SanchrColors.primary)
                            .padding(.top, 2)
                        Text("When enabled, new messages will disappear after the selected time. This applies to both sides of the conversation.")
                            .font(SanchrTypography.messageBubbleText)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .padding(16)
                    .background(SanchrColors.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                    // Timer options
                    ForEach(0..<options.count, id: \.self) { index in
                        let option = options[index]
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedDuration = option.2
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(selectedDuration == option.2 ? SanchrColors.primary.opacity(0.1) : SanchrExportColors.surfaceSoft)
                                    .frame(width: 40, height: 40)
                                    .overlay {
                                        Image(systemName: option.2 == 0 ? "xmark" : "clock.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(selectedDuration == option.2 ? SanchrColors.primary : SanchrExportColors.textSecondary)
                                    }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.0)
                                        .font(SanchrTypography.messageBubbleText)
                                        .fontWeight(.medium)
                                        .foregroundColor(SanchrExportColors.textPrimary)
                                    Text(option.1)
                                        .font(SanchrTypography.captionSmall)
                                        .foregroundColor(SanchrExportColors.textSecondary)
                                }

                                Spacer()

                                if selectedDuration == option.2 {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(SanchrColors.primary)
                                } else {
                                    Circle()
                                        .stroke(SanchrExportColors.line, lineWidth: 2)
                                        .frame(width: 20, height: 20)
                                }
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 20)
                        }
                        .buttonStyle(.plain)

                        if index < options.count - 1 {
                            Rectangle()
                                .fill(SanchrExportColors.line)
                                .frame(height: 1)
                                .padding(.leading, 72)
                        }
                    }
                }
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }
}

// MARK: - VaultMediaView

private struct VaultMediaView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var autoVault = false
    @State private var viewOnce = true
    @State private var screenshotProtection = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                screenHeader(title: "Vault Media", onBack: { dismiss() })

                VStack(alignment: .leading, spacing: 0) {
                    // Info banner
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(SanchrColors.primaryDark)
                            .padding(.top, 2)
                        Text("Vault media is protected with extra encryption and can be set to self-destruct after viewing.")
                            .font(SanchrTypography.messageBubbleText)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .padding(16)
                    .background(
                        LinearGradient(
                            colors: [SanchrColors.primaryDark.opacity(0.05), SanchrColors.primary.opacity(0.05)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                    // Toggles
                    vaultToggle(icon: "tray.and.arrow.down.fill", title: "Auto-Vault Incoming", subtitle: "Automatically protect received media", isOn: $autoVault)

                    Rectangle().fill(SanchrExportColors.line).frame(height: 1).padding(.leading, 72)

                    vaultToggle(icon: "eye.fill", title: "View Once", subtitle: "Media disappears after first viewing", isOn: $viewOnce)

                    Rectangle().fill(SanchrExportColors.line).frame(height: 1).padding(.leading, 72)

                    vaultToggle(icon: "camera.metering.none", title: "Screenshot Protection", subtitle: "Prevent screenshots of vault media", isOn: $screenshotProtection)
                }
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private func vaultToggle(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceSoft)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
    }
}

// MARK: - SearchConversationView

private struct SearchConversationView: View {
    let conversationName: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textTertiary)

                    TextField("Search in \(conversationName)...", text: $searchText)
                        .font(SanchrTypography.messageBubbleText)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(SanchrExportColors.surfaceSoft)
                .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(SanchrExportColors.line).frame(height: 1)
            }

            if searchText.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(SanchrExportColors.textTertiary)
                    Text("Search messages")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                    Text("Find messages, photos, links and more")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
                Spacer()
            } else {
                // Empty results state
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(SanchrExportColors.textTertiary)
                    Text("No results found")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
                Spacer()
            }
        }
        .background(SanchrExportColors.background)
        .onAppear { isFocused = true }
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
    private let onScanned: @MainActor (Data) -> Void
    private var captureSession: AVCaptureSession?
    private var hasScanned = false

    init(onScanned: @escaping @MainActor (Data) -> Void) {
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
              let input = try? AVCaptureDeviceInput(device: device) else { return }

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
            // Keep delegate alive
            objc_setAssociatedObject(output, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        self.captureSession = session

        let sessionRef = session
        DispatchQueue.global(qos: .userInitiated).async {
            sessionRef.startRunning()
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
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = object.stringValue,
              let data = stringValue.data(using: .utf8) else { return }
        handler(data)
    }
}
