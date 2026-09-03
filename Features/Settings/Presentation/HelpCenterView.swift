import SwiftUI
import SanchrShared

/// Help center screen.
/// Matches Figma: help-center-screen.
/// Provides FAQ sections, support entry points, and local topic cards.
struct HelpCenterView: View {
    @State private var searchText = ""
    @State private var expandedFAQ: String?
    @State private var showContactForm = false

    private let popularTopics: [(String, String, String)] = [
        ("shield", "End-to-End Encryption", "How it works"),
        ("key", "Verify Security Keys", "QR code verification"),
        ("eye.slash", "Sanchr Mode Privacy", "Enhanced protection"),
        ("clock.arrow.circlepath", "Self-Destructing Media", "Vault feature guide"),
        ("icloud.and.arrow.up", "Backup & Restore", "Keep your data safe"),
    ]

    private let categories: [(String, String, String)] = [
        ("sparkles", "Getting Started", "12 articles"),
        ("lock", "Security", "18 articles"),
        ("gearshape", "Settings", "15 articles"),
        ("questionmark.circle", "Troubleshooting", "22 articles"),
        ("phone", "Calls", "9 articles"),
        ("person.3", "Groups", "11 articles"),
    ]

    private let faqs: [(String, String)] = [
        ("How secure is Sanchr?", "Sanchr uses end-to-end encryption for messages, calls, and media. Only you and the intended recipient can decrypt the contents."),
        ("What is Sanchr Mode?", "Sanchr Mode is an enhanced privacy feature that hides message previews and reduces passive visibility across the interface."),
        ("Can I back up my chats?", "Yes. Sanchr supports encrypted backups so your data can be restored on a new device without exposing message contents."),
        ("How do I verify contacts?", "Open a conversation, tap the contact header, and use Verify Security Code to compare the QR code or numeric fingerprint.")
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                searchSection
                quickActions
                popularTopicsSection
                categoriesSection
                faqSection
                supportCTA
                communitySection
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Help Center")
        .sheet(isPresented: $showContactForm) {
            ContactSupportForm()
        }
    }

    private var searchSection: some View {
        SanchrSearchField(placeholder: "Search for help...", text: $searchText) {
            EmptyView()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button {
                showContactForm = true
            } label: {
                quickActionCard(
                    title: "Live Chat",
                    subtitle: "Get instant help",
                    icon: "message"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                showContactForm = true
            } label: {
                quickActionCard(
                    title: "Email Us",
                    subtitle: "We'll respond soon",
                    icon: "envelope"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var popularTopicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Popular Topics")

            VStack(spacing: 12) {
                ForEach(popularTopics, id: \.1) { icon, title, subtitle in
                    HStack(spacing: 14) {
                        iconTile(systemName: icon)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(SanchrExportColors.textPrimary)
                            Text(subtitle)
                                .font(SanchrTypography.caption)
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                    .padding(16)
                    .settingsCard()
                }
            }
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Browse by Category")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(categories, id: \.1) { icon, title, subtitle in
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsIconTile(systemName: icon, size: 48, iconSize: 18)

                        Text(title)
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(subtitle)
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .settingsCard()
                }
            }
        }
    }

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Frequently Asked")

            VStack(spacing: 12) {
                ForEach(faqs, id: \.0) { question, answer in
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedFAQ = expandedFAQ == question ? nil : question
                            }
                        } label: {
                            HStack {
                                Text(question)
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                                    .rotationEffect(.degrees(expandedFAQ == question ? 180 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if expandedFAQ == question {
                            Text(answer)
                                .font(SanchrTypography.caption)
                                .foregroundColor(SanchrExportColors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                    }
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var supportCTA: some View {
        VStack(spacing: 12) {
            SettingsIconTile(systemName: "headphones", role: .accent, size: 64, iconSize: 26)

            Text("Still Need Help?")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text("Our support team is available to help with setup, security, and account issues.")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)

            Button("Contact Support") {
                showContactForm = true
            }
            .font(SanchrTypography.bodyBold)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .frame(height: 46)
            .background(Color.sanchrPrimary)
            .clipShape(Capsule())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .settingsCard(cornerRadius: 26)
    }

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Community")

            VStack(spacing: 12) {
                communityRow(icon: "at", title: "Twitter", subtitle: "@Sanchr")
                communityRow(icon: "bubble.left.and.bubble.right", title: "Discord", subtitle: "Join our server")
                communityRow(icon: "text.bubble", title: "Reddit", subtitle: "r/Sanchr")
            }
        }
    }

    private func quickActionCard(
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsIconTile(systemName: icon, role: .accent, size: 48, iconSize: 18)

            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text(subtitle)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
    }

    private func iconTile(systemName: String) -> some View {
        SettingsIconTile(systemName: systemName)
    }

    private func communityRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(16)
        .settingsCard()
    }

    private func sectionTitle(_ title: String) -> some View {
        SettingsSectionTitle(title: title)
    }
}

struct ContactSupportForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var message = ""
    @State private var includeDeviceInfo = true

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    field(title: "Subject", text: $subject, placeholder: "How can we help?")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Message")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)

                        TextEditor(text: $message)
                            .font(SanchrTypography.body)
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .frame(minHeight: 180)
                            .padding(12)
                            .scrollContentBackground(.hidden)
                            .background(SanchrExportColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
                            }
                    }

                    Toggle(isOn: $includeDeviceInfo) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Include device info")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(SanchrExportColors.textPrimary)
                            Text("Attach device model, iOS version, and app version for faster troubleshooting.")
                                .font(SanchrTypography.caption)
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                    }
                    .tint(.sanchrPrimary)
                    .padding(18)
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
                    }
                }
                .padding(SanchrExportMetrics.sectionHorizontal)
                .padding(.top, 16)
            }
            .sanchrSettingsSubscreenNavigation(title: "Contact Support")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendSupportEmail()
                        dismiss()
                    }
                    .disabled(subject.isEmpty || message.isEmpty)
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
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
                }
        }
    }

    private func sendSupportEmail() {
        var body = message
        if includeDeviceInfo {
            let device = UIDevice.current
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            body += "\n\n---\nDevice: \(device.model)\niOS: \(device.systemVersion)\nApp: \(appVersion)"
        }

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(string: "mailto:support@sanchr.io?subject=\(encodedSubject)&body=\(encodedBody)") {
            UIApplication.shared.open(url)
        }
    }
}
