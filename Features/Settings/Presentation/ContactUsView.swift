import SwiftUI
import SanchrShared

struct ContactUsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var topic = "General Support"
    @State private var message = ""
    @State private var includeDeviceInfo = true

    private let topics = [
        "General Support",
        "Account Access",
        "Billing",
        "Security Concerns",
        "Report Abuse",
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                header
                heroCard
                quickLinks
                formCard
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private var header: some View {
        SanchrCenteredHeader(title: "Contact Us") {
            SanchrIconButton(systemName: "chevron.left") {
                dismiss()
            }
        } trailing: {
            Color.clear
        }
    }

    private var heroCard: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xEEF2FF), Color(hex: 0xECFEFF)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 168)
                .overlay {
                    VStack(spacing: 14) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: "envelope.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(.white)
                            }

                        VStack(spacing: 6) {
                            Text("We're Here to Help")
                                .font(SanchrTypography.sectionHeader)
                                .foregroundColor(SanchrExportColors.textPrimary)

                            Text("Tell us what's happening and we'll route it to the right team.")
                                .font(SanchrTypography.body)
                                .foregroundColor(SanchrExportColors.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 24)
                }
        }
    }

    private var quickLinks: some View {
        VStack(spacing: 12) {
            ContactLinkRow(
                icon: "questionmark.circle.fill",
                tint: SanchrColors.primary,
                title: "Help Center",
                subtitle: "Browse FAQs and setup guides"
            )

            ContactLinkRow(
                icon: "envelope.badge.fill",
                tint: SanchrColors.accent,
                title: "support@sanchr.io",
                subtitle: "General support inbox"
            )

            ContactLinkRow(
                icon: "exclamationmark.shield.fill",
                tint: SanchrColors.error,
                title: "emergency@sanchr.io",
                subtitle: "Urgent account or safety concerns"
            )
        }
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send a Message")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(SanchrExportColors.textPrimary)

            field(title: "Name", text: $name, placeholder: "Your name")
            field(title: "Email", text: $email, placeholder: "you@example.com")

            VStack(alignment: .leading, spacing: 8) {
                Text("Topic")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)

                Menu {
                    ForEach(topics, id: \.self) { topic in
                        Button(topic) {
                            self.topic = topic
                        }
                    }
                } label: {
                    HStack {
                        Text(topic)
                            .font(SanchrTypography.body)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(SanchrExportColors.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Message")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)

                TextEditor(text: $message)
                    .font(UIFont(name: "Afacad", size: 16) == nil ? .body : .custom("Afacad", size: 16))
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .frame(minHeight: 150)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(SanchrExportColors.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            Toggle(isOn: $includeDeviceInfo) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Include device info")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text("Adds device model, OS version, and app version to help support troubleshoot.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
            }
            .tint(.sanchrPrimary)

            Button {} label: {
                SanchrGradientButtonLabel(title: "Send Message", systemName: "paperplane.fill")
            }
            .buttonStyle(SanchrPrimaryCTA())
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 1)
        }
        .padding(20)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(hex: 0xEEF2F7), lineWidth: 1)
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)

            TextField(placeholder, text: text)
                .font(SanchrTypography.body)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(SanchrExportColors.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct ContactLinkRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.sanchrPrimary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(hex: 0xEEF2F7), lineWidth: 1)
        }
    }
}
