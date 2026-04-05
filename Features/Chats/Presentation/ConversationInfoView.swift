import SwiftUI
import Kingfisher

struct ConversationInfoView: View {
    let conversation: Conversation
    let recipient: User?

    @Environment(\.dismiss) private var dismiss
    @State private var notificationsMuted = false
    @State private var mediaVisibility = true
    @State private var sanchrModeEnabled = false

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

                Text(recipient?.phoneNumber ?? "")
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrExportColors.textSecondary)

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

            settingsRow(
                icon: "touchid",
                iconBg: SanchrColors.primary.opacity(0.1),
                iconColor: SanchrColors.primary,
                title: "Encryption Keys",
                subtitle: "View security fingerprint"
            )
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

            settingsRow(
                icon: "paintpalette.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Wallpaper & Theme",
                subtitle: "Customize chat appearance"
            )
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
            settingsRow(
                icon: "clock.arrow.circlepath",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Disappearing Messages",
                subtitle: "Off"
            )

            settingsRow(
                icon: "lock.shield.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Vault Media",
                subtitle: "Self-destructing photos & videos"
            )
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
            settingsRow(
                icon: "magnifyingglass",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Search in Conversation"
            )

            settingsRow(
                icon: "square.and.arrow.down.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Export Chat",
                subtitle: "Save conversation backup"
            )
            .padding(.top, 8)

            settingsRow(
                icon: "trash.fill",
                iconBg: SanchrExportColors.surfaceSoft,
                iconColor: SanchrExportColors.textSecondary,
                title: "Clear Chat",
                subtitle: "Delete all messages"
            )
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
            Button {} label: {
                dangerRow(icon: "person.fill.xmark", title: "Block Contact")
            }
            .buttonStyle(.plain)

            Button {} label: {
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
        .padding(.top, 56)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary, SanchrColors.primaryDark],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea(edges: .top)
        )
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
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 280)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 220, height: 220)
                        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
                        .overlay {
                            Image(systemName: "qrcode")
                                .font(.system(size: 120))
                                .foregroundColor(SanchrExportColors.textPrimary)
                        }
                }

            Button {} label: {
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
                Button {} label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy")
                            .font(SanchrTypography.messageBubbleText)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(SanchrColors.primary)
                }
                .buttonStyle(.plain)
            }

            let fingerprint = [
                ["28394", "75621", "94857", "63294", "12847"],
                ["58392", "67483", "92847", "38475", "84729"],
                ["39485", "73829", "48573", "92847", "58392"]
            ]

            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<5, id: \.self) { col in
                            Text(fingerprint[row][col])
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(SanchrExportColors.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
                        }
                    }
                }
            }
            .padding(20)
            .background(Color(hex: 0xF9FAFB))
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
                iconBg: Color(hex: 0xDCFCE7),
                iconColor: Color(hex: 0x16A34A),
                title: "Verification Status",
                subtitle: nil,
                statusText: "Verified on Dec 8, 2024",
                gradientStart: Color(hex: 0xF0FDF4),
                gradientEnd: Color(hex: 0xECFDF5),
                borderColor: Color(hex: 0xBBF7D0)
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
            LinearGradient(
                colors: [gradientStart, gradientEnd],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
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
        .background(
            LinearGradient(
                colors: [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Footer

    private var verifyFooter: some View {
        VStack(spacing: 0) {
            Button {} label: {
                SanchrGradientButtonLabel(title: "Mark as Verified", systemName: "checkmark.shield.fill")
            }
            .buttonStyle(SanchrPrimaryCTA())
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
