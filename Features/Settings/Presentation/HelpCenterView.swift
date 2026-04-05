import SwiftUI

/// Help center screen.
/// Matches Figma: help-center-screen.
/// Provides FAQ sections, support entry points, and local topic cards.
struct HelpCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var expandedFAQ: String?
    @State private var showContactForm = false

    private let popularTopics: [(String, String, String, Color, Color)] = [
        ("shield.fill", "End-to-End Encryption", "How it works", SanchrColors.primary, Color(hex: 0xEEF2FF)),
        ("key.fill", "Verify Security Keys", "QR code verification", SanchrColors.accent, Color(hex: 0xECFEFF)),
        ("eye.slash.fill", "Sanchr Mode Privacy", "Enhanced protection", Color(hex: 0x7C3AED), Color(hex: 0xF3E8FF)),
        ("clock.arrow.circlepath", "Self-Destructing Media", "Vault feature guide", Color(hex: 0xEC4899), Color(hex: 0xFCE7F3)),
        ("icloud.and.arrow.up.fill", "Backup & Restore", "Keep your data safe", Color(hex: 0x16A34A), Color(hex: 0xDCFCE7)),
    ]

    private let categories: [(String, String, String, [Color])] = [
        ("rocket.fill", "Getting Started", "12 articles", [SanchrColors.primary, Color(hex: 0x4F46E5)]),
        ("lock.fill", "Security", "18 articles", [SanchrColors.accent, Color(hex: 0x0891B2)]),
        ("gearshape.fill", "Settings", "15 articles", [Color(hex: 0x8B5CF6), Color(hex: 0x7C3AED)]),
        ("questionmark.circle.fill", "Troubleshooting", "22 articles", [Color(hex: 0xEC4899), Color(hex: 0xDB2777)]),
        ("phone.fill", "Calls", "9 articles", [Color(hex: 0xF97316), Color(hex: 0xEA580C)]),
        ("person.3.fill", "Groups", "11 articles", [Color(hex: 0x22C55E), Color(hex: 0x16A34A)]),
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
                header
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
        .navigationBarHidden(true)
        .sheet(isPresented: $showContactForm) {
            ContactSupportForm()
        }
    }

    private var header: some View {
        SanchrCenteredHeader(title: "Help Center") {
            SanchrIconButton(systemName: "chevron.left") {
                dismiss()
            }
        } trailing: {
            Color.clear
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
                    icon: "message.fill",
                    colors: [SanchrColors.primary, Color(hex: 0x4F46E5)],
                    foreground: .white
                )
            }
            .buttonStyle(.plain)

            Button {
                showContactForm = true
            } label: {
                quickActionCard(
                    title: "Email Us",
                    subtitle: "We'll respond soon",
                    icon: "envelope.fill",
                    colors: [SanchrColors.accent, Color(hex: 0x0891B2)],
                    foreground: .white
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var popularTopicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Popular Topics")

            VStack(spacing: 12) {
                ForEach(popularTopics, id: \.1) { icon, title, subtitle, tint, background in
                    HStack(spacing: 14) {
                        iconTile(systemName: icon, tint: tint, background: background)

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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                    .padding(16)
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Browse by Category")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(categories, id: \.1) { icon, title, subtitle, colors in
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: colors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 48, height: 48)
                            .overlay {
                                Image(systemName: icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }

                        Text(title)
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(subtitle)
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                    }
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
                            .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var supportCTA: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "headphones")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                }

            Text("Still Need Help?")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(.white)

            Text("Our support team is available to help with setup, security, and account issues.")
                .font(SanchrTypography.caption)
                .foregroundColor(.white.opacity(0.88))
                .multilineTextAlignment(.center)

            Button("Contact Support") {
                showContactForm = true
            }
            .font(SanchrTypography.bodyBold)
            .foregroundColor(.sanchrPrimary)
            .padding(.horizontal, 24)
            .frame(height: 46)
            .background(Color.white)
            .clipShape(Capsule())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary, Color(hex: 0x4F46E5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Community")

            VStack(spacing: 12) {
                communityRow(icon: "bird.fill", tint: Color(hex: 0x3B82F6), title: "Twitter", subtitle: "@Sanchr")
                communityRow(icon: "bubble.left.and.bubble.right.fill", tint: Color(hex: 0x7C3AED), title: "Discord", subtitle: "Join our server")
                communityRow(icon: "text.bubble.fill", tint: Color(hex: 0xF97316), title: "Reddit", subtitle: "r/Sanchr")
            }
        }
    }

    private func quickActionCard(
        title: String,
        subtitle: String,
        icon: String,
        colors: [Color],
        foreground: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(foreground)
                }

            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(foreground)

            Text(subtitle)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(foreground.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func iconTile(systemName: String, tint: Color, background: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SanchrExportColors.surfaceMuted)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.sanchrPrimary)
            }
    }

    private func communityRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon, tint: tint, background: tint.opacity(0.12))

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
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SanchrTypography.sectionLabel)
            .tracking(1.2)
            .foregroundColor(SanchrExportColors.textSecondary)
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
                            .font(UIFont(name: "Afacad", size: 16) == nil ? .body : .custom("Afacad", size: 16))
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .frame(minHeight: 180)
                            .padding(12)
                            .scrollContentBackground(.hidden)
                            .background(SanchrExportColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
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
                            .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                    }
                }
                .padding(SanchrExportMetrics.sectionHorizontal)
                .padding(.top, 16)
            }
            .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
            .navigationTitle("Contact Support")
            .navigationBarTitleDisplayMode(.inline)
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
                        .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
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
