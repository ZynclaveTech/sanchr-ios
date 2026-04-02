import SwiftUI

/// Chat-specific settings screen.
/// Matches Figma: chat-settings-main.
struct ChatSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var enterSendsMessage = true
    @State private var mediaQuality = "Standard"
    @State private var fontSize = "Medium"
    @State private var linkPreviews = true

    private let qualityOptions = ["Low", "Standard", "High"]
    private let fontSizeOptions = ["Small", "Medium", "Large"]

    var body: some View {
        List {
            Section("Input") {
                Toggle("Enter sends message", isOn: $enterSendsMessage)
                    .tint(.sanchrPrimary)
                Toggle("Link previews", isOn: $linkPreviews)
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Media") {
                Picker("Photo quality", selection: $mediaQuality) {
                    ForEach(qualityOptions, id: \.self) { Text($0) }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Display") {
                Picker("Font size", selection: $fontSize) {
                    ForEach(fontSizeOptions, id: \.self) { Text($0) }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Disappearing Messages") {
                // TODO: Default disappearing message timer
                HStack {
                    Text("Default timer")
                    Spacer()
                    Text("Off")
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chat Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
