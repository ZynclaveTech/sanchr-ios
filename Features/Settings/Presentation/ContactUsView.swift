import SwiftUI
import SanchrShared

struct ContactUsView: View {
    @Environment(\.colorScheme) private var colorScheme
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
                heroCard
                quickLinks
                formCard
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .sanchrSettingsSubscreenNavigation(title: "Contact Us")
    }

    private var heroCard: some View {
        VStack(spacing: 14) {
            SettingsIconTile(systemName: "envelope", role: .accent, size: 64, iconSize: 24)

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
        .padding(24)
        .frame(maxWidth: .infinity)
        .settingsCard()
    }

    private var quickLinks: some View {
        VStack(spacing: 12) {
            ContactLinkRow(
                icon: "questionmark.circle",
                title: "Help Center",
                subtitle: "Browse FAQs and setup guides"
            )

            ContactLinkRow(
                icon: "envelope.badge",
                title: "support@sanchr.com",
                subtitle: "General support inbox"
            )

            ContactLinkRow(
                icon: "exclamationmark.shield",
                title: "emergency@sanchr.com",
                subtitle: "Urgent account or safety concerns",
                role: .destructive
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
                    .sanchrFieldBackground(colorScheme)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Message")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)

                TextEditor(text: $message)
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .frame(minHeight: 150)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .sanchrFieldBackground(colorScheme)
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

            Button { sendSupportEmail() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane")
                        .symbolRenderingMode(.monochrome)
                    Text("Send Message")
                }
                .font(SanchrTypography.bodyBold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.sanchrPrimary)
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 1)
        }
        .padding(20)
        .settingsCard(cornerRadius: 24)
    }

    private func sendSupportEmail() {
        let subject = "[Support] \(topic)"
        var body = "Name: \(name)\nEmail: \(email)\n\n\(message)"

        if includeDeviceInfo {
            let device = UIDevice.current
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            body += "\n\n---\nDevice: \(device.model) (\(device.systemName) \(device.systemVersion))\nApp: Sanchr v\(appVersion) (\(buildNumber))"
        }

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(string: "mailto:support@sanchr.com?subject=\(encodedSubject)&body=\(encodedBody)") {
            UIApplication.shared.open(url) { success in
                if !success {
                    UIPasteboard.general.string = "To: support@sanchr.com\nSubject: \(subject)\n\n\(body)"
                }
            }
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
                .sanchrFieldBackground(colorScheme)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct ContactLinkRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var role: SettingsIconRole = .neutral

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemName: icon, role: role, size: 48, iconSize: 18)

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
        .settingsCard(cornerRadius: 20)
    }
}
