import SwiftUI

/// Privacy settings screen.
/// Matches Figma: privacy-screen.
struct PrivacyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastSeenVisibility = "Contacts"
    @State private var profilePhotoVisibility = "Everyone"
    @State private var readReceipts = true
    @State private var typingIndicators = true
    @State private var screenshotAlerts = true

    private let visibilityOptions = ["Everyone", "Contacts", "Nobody"]

    var body: some View {
        List {
            Section("Visibility") {
                Picker("Last seen", selection: $lastSeenVisibility) {
                    ForEach(visibilityOptions, id: \.self) { Text($0) }
                }
                Picker("Profile photo", selection: $profilePhotoVisibility) {
                    ForEach(visibilityOptions, id: \.self) { Text($0) }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Interactions") {
                Toggle("Read receipts", isOn: $readReceipts)
                    .tint(.sanchrPrimary)
                Toggle("Typing indicators", isOn: $typingIndicators)
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Security") {
                Toggle("Screenshot alerts", isOn: $screenshotAlerts)
                    .tint(.sanchrPrimary)

                NavigationLink {
                    // TODO: Blocked contacts list
                    Text("Blocked Contacts")
                } label: {
                    Text("Blocked contacts")
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
