import MessageUI
import SwiftUI

/// Help center screen.
/// Matches Figma: help-center-screen.
/// Provides FAQ sections, contact support form, documentation link, and emergency support.
struct HelpCenterView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedFAQ: String?
    @State private var showContactForm = false
    @State private var showEmergencyInfo = false

    private let faqSections: [(category: String, items: [(question: String, answer: String)])] = [
        (
            "Privacy & Security",
            [
                (
                    "How is my data protected?",
                    "All messages, calls, and vault items are end-to-end encrypted using the Signal Protocol. We cannot read your messages. Encryption keys are generated and stored only on your device."
                ),
                (
                    "What is Vync Mode?",
                    "Vync Mode is an enhanced privacy mode that disables read receipts, typing indicators, online status, and enables screenshot protection all at once."
                ),
                (
                    "Can Sanchr read my messages?",
                    "No. Sanchr uses end-to-end encryption. Messages are encrypted on your device and can only be decrypted by the intended recipient. We never have access to your message content."
                ),
            ]
        ),
        (
            "Account & Setup",
            [
                (
                    "Can I use Sanchr on multiple devices?",
                    "Multi-device support is coming soon. Currently, Sanchr works on a single device per account."
                ),
                (
                    "What happens if I lose my phone?",
                    "Your encryption keys are stored only on your device. If you lose your phone, you will need to re-register and re-verify with your contacts."
                ),
                (
                    "How do I change my phone number?",
                    "Phone number changes are not yet supported. You will need to create a new account with the new number."
                ),
            ]
        ),
        (
            "Features",
            [
                (
                    "How do disappearing messages work?",
                    "Disappearing messages are automatically deleted after the set timer expires on both your device and the recipient's device. Once deleted, they cannot be recovered."
                ),
                (
                    "What is the Vault?",
                    "The Vault is encrypted secure storage for your sensitive files. Photos, videos, and documents stored in the Vault are protected with AES-256 encryption and can self-destruct after a set time."
                ),
                (
                    "How do voice and video calls work?",
                    "Calls use WebRTC with SRTP encryption. Audio and video streams are encrypted end-to-end between you and the other participant. Call metadata is minimally stored."
                ),
            ]
        ),
    ]

    var body: some View {
        List {
            // MARK: - FAQ Sections
            ForEach(faqSections, id: \.category) { section in
                Section(section.category) {
                    ForEach(section.items, id: \.question) { item in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedFAQ == item.question },
                                set: { isExpanded in
                                    expandedFAQ = isExpanded ? item.question : nil
                                }
                            )
                        ) {
                            Text(item.answer)
                                .font(SanchrTypography.caption)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                                .padding(.vertical, SanchrSpacing.xxs)
                        } label: {
                            Text(item.question)
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        }
                    }
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))
            }

            // MARK: - Contact Support
            Section("Contact Us") {
                Button {
                    showContactForm = true
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.sanchrPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                            Text("Email Support")
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text("support@sanchr.io")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                    }
                }

                Button {
                    if let url = URL(string: "https://docs.sanchr.io") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "book.fill")
                            .foregroundColor(.sanchrPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                            Text("Documentation")
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text("docs.sanchr.io")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                    }
                }

                Button {
                    if let url = URL(string: "https://sanchr.io") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "globe")
                            .foregroundColor(.sanchrPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                            Text("Visit our website")
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text("sanchr.io")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Emergency Support
            Section {
                Button {
                    showEmergencyInfo = true
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.sanchrError)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                            Text("Emergency Support")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text("Account compromise, harassment, or safety concerns")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - App Info
            Section {
                HStack {
                    Text("App Version")
                        .font(SanchrTypography.body)
                    Spacer()
                    Text(
                        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                            ?? "1.0.0"
                    )
                    .font(SanchrTypography.caption)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }

                HStack {
                    Text("Build")
                        .font(SanchrTypography.body)
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Help Center")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showContactForm) {
            ContactSupportForm()
        }
        .alert("Emergency Support", isPresented: $showEmergencyInfo) {
            Button("Email emergency@sanchr.io") {
                if let url = URL(
                    string: "mailto:emergency@sanchr.io?subject=Emergency%20Support%20Request")
                {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "If you believe your account has been compromised or you are experiencing harassment, contact our emergency support team immediately."
            )
        }
    }
}

// MARK: - Contact Support Form

struct ContactSupportForm: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var message = ""
    @State private var includeDeviceInfo = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Subject", text: $subject)
                        .font(SanchrTypography.body)
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))

                Section {
                    TextEditor(text: $message)
                        .font(SanchrTypography.body)
                        .frame(minHeight: 150)
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))

                Section {
                    Toggle("Include device info", isOn: $includeDeviceInfo)
                        .tint(.sanchrPrimary)
                    Text(
                        "Helps us diagnose issues faster. Includes device model, OS version, and app version."
                    )
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))
            }
            .listStyle(.insetGrouped)
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

    private func sendSupportEmail() {
        var body = message
        if includeDeviceInfo {
            let device = UIDevice.current
            body +=
                "\n\n---\nDevice: \(device.model)\niOS: \(device.systemVersion)\nApp: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
        }

        let encodedSubject =
            subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(
            string: "mailto:support@sanchr.io?subject=\(encodedSubject)&body=\(encodedBody)")
        {
            UIApplication.shared.open(url)
        }
    }
}
