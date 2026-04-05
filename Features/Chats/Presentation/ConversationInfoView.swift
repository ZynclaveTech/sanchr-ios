import SwiftUI
import Kingfisher

struct ConversationInfoView: View {
    let conversation: Conversation
    let recipient: User?

    @Environment(\.dismiss) private var dismiss
    @State private var disappearingMessages = true
    @State private var mediaAutoSave = false
    @State private var vaultShield = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                settingsHeader
                profileSection
                // mediaSection, securitySection, etc. will be added in later tasks
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

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text(recipient?.phoneNumber ?? "")
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrExportColors.textSecondary)

                HStack(spacing: 6) {
                    Text("End-to-End Encrypted")
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.medium)
                        .foregroundColor(SanchrColors.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SanchrColors.accent.opacity(0.1))
                        .clipShape(Capsule())
                }
                .padding(.top, 4)
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

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shared Media")
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(mediaGradient(for: index))
                        .frame(height: 92)
                        .overlay(alignment: .bottomTrailing) {
                            if index == 0 {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                                    .padding(8)
                            }
                        }
                }
            }
        }
        .padding(20)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy Controls")
                .font(SanchrTypography.sectionLabel)
                .tracking(1.2)
                .foregroundColor(SanchrExportColors.textSecondary)

            ConversationToggleRow(
                icon: "timer",
                tint: SanchrColors.primary,
                title: "Disappearing Messages",
                subtitle: "Automatically remove new messages after the timer ends",
                isOn: $disappearingMessages
            )

            Divider()

            ConversationToggleRow(
                icon: "square.and.arrow.down.fill",
                tint: SanchrColors.accent,
                title: "Auto-save Media",
                subtitle: "Keep received photos and videos available offline",
                isOn: $mediaAutoSave
            )

            Divider()

            ConversationToggleRow(
                icon: "lock.doc.fill",
                tint: Color(hex: 0x7C3AED),
                title: "Vault Shield",
                subtitle: "Default incoming media into Vault protections",
                isOn: $vaultShield
            )
        }
        .padding(20)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Encryption & Security")
                .font(SanchrTypography.sectionLabel)
                .tracking(1.2)
                .foregroundColor(SanchrExportColors.textSecondary)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SanchrColors.primary, SanchrColors.primaryDark],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 92)
                .overlay(alignment: .leading) {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("End-to-End Encryption")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(.white)
                            Text("Only you and this contact can read the contents of this chat.")
                                .font(SanchrTypography.caption)
                                .foregroundColor(.white.opacity(0.86))
                        }
                    }
                    .padding(.horizontal, 18)
                }

            NavigationLink {
                VerifySecurityCodeView(conversation: conversation)
            } label: {
                ConversationChevronRow(
                    icon: "number.square.fill",
                    tint: SanchrColors.accent,
                    title: "Security Code",
                    subtitle: "Compare QR or fingerprint values"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Backup & Storage")
                .font(SanchrTypography.sectionLabel)
                .tracking(1.2)
                .foregroundColor(SanchrExportColors.textSecondary)

            ConversationChevronRow(
                icon: "lock.doc.fill",
                tint: Color(hex: 0x7C3AED),
                title: "Vault Settings",
                subtitle: "Expiration defaults and secure media rules"
            )

            Divider()

            ConversationChevronRow(
                icon: "internaldrive.fill",
                tint: SanchrColors.primary,
                title: "Storage Usage",
                subtitle: "1.2 GB of media cached in this conversation"
            )
        }
        .padding(20)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

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

private struct ConversationToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sanchrPrimary)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
    }
}

private struct ConversationChevronRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.sanchrPrimary)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
    }
}

private struct VerifySecurityCodeView: View {
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                SanchrCenteredHeader(title: "Verify Security Code") {
                    SanchrIconButton(systemName: "chevron.left") { dismiss() }
                } trailing: {
                    Color.clear
                }

                VStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xEEF2FF), Color(hex: 0xECFEFF)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 220)
                        .overlay {
                            VStack(spacing: 16) {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(SanchrExportColors.surface)
                                    .frame(width: 164, height: 164)
                                    .overlay {
                                        VStack(spacing: 8) {
                                            Image(systemName: "qrcode")
                                                .font(.system(size: 72))
                                                .foregroundColor(SanchrExportColors.textPrimary)
                                            Text("Scan to verify")
                                                .font(SanchrTypography.caption)
                                                .foregroundColor(SanchrExportColors.textSecondary)
                                        }
                                    }

                                Text(conversation.displayName)
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                            }
                        }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Security Fingerprint")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)

                        Text("28394 75621 94857 10293\n48375 18472 92015 66741")
                            .font(UIFont(name: "Afacad", size: 22) == nil ? .system(size: 22, weight: .semibold, design: .rounded) : .custom("Afacad", size: 22))
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .lineSpacing(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(SanchrExportColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }

                    Button {} label: {
                        SanchrGradientButtonLabel(title: "Mark as Verified", systemName: "checkmark.shield.fill")
                    }
                    .buttonStyle(SanchrPrimaryCTA())
                }
                .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                .padding(.bottom, 28)
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }
}
