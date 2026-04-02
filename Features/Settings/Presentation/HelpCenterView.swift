import SwiftUI

/// Help center screen.
/// Matches Figma: help-center-screen.
struct HelpCenterView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let faqItems: [(question: String, answer: String)] = [
        ("How is my data protected?",
         "All messages, calls, and vault items are end-to-end encrypted using the Signal Protocol. We cannot read your messages."),
        ("Can I use Sanchr on multiple devices?",
         "Multi-device support is coming soon. Currently, Sanchr works on a single device per account."),
        ("How do disappearing messages work?",
         "Disappearing messages are automatically deleted after the set timer expires on both your device and the recipient's device."),
        ("What happens if I lose my phone?",
         "Your encryption keys are stored only on your device. If you lose your phone, you will need to re-register and re-verify with your contacts."),
    ]

    var body: some View {
        List {
            Section("Frequently Asked Questions") {
                ForEach(faqItems, id: \.question) { item in
                    DisclosureGroup {
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

            Section("Contact Us") {
                Button {
                    // TODO: Open email composer
                } label: {
                    Label("Email support", systemImage: "envelope.fill")
                }

                Button {
                    // TODO: Open support website
                } label: {
                    Label("Visit our website", systemImage: "globe")
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Help Center")
        .navigationBarTitleDisplayMode(.inline)
    }
}
