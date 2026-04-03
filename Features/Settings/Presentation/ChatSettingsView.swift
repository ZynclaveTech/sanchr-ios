import SwiftUI

/// Chat-specific settings screen.
/// Matches Figma: chat-settings-main.
/// Syncs chat bubble style, enter key, media auto-save, and backup settings to backend.
struct ChatSettingsView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = SettingsViewModel()

    // Local-only settings (not in gRPC proto)
    @State private var enterSendsMessage = true
    @State private var linkPreviews = true
    @State private var mediaAutoSave = false
    @State private var chatBubbleStyle = "modern"
    @State private var backupEnabled = false

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let bubbleStyles = [
        ("Modern", "modern"),
        ("Classic", "classic"),
        ("Compact", "compact"),
    ]

    private let fontSizeOptions = ["small", "medium", "large"]

    private let disappearingTimerOptions = [
        ("Off", "off"),
        ("5 seconds", "5s"),
        ("30 seconds", "30s"),
        ("1 minute", "1m"),
        ("5 minutes", "5m"),
        ("1 hour", "1h"),
        ("24 hours", "24h"),
        ("7 days", "7d"),
    ]

    var body: some View {
        List {
            // MARK: - Chat Bubble Style
            Section("Chat Bubble Style") {
                ForEach(bubbleStyles, id: \.1) { name, value in
                    HStack {
                        // Preview bubble
                        RoundedRectangle(cornerRadius: bubbleRadius(value))
                            .fill(Color.sanchrPrimary)
                            .frame(width: 60, height: 28)
                            .overlay {
                                Text("Hi!")
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(.white)
                            }

                        Text(name)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                        Spacer()

                        if chatBubbleStyle == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        chatBubbleStyle = value
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Input
            Section("Input") {
                Toggle("Enter key sends message", isOn: $enterSendsMessage)
                    .tint(.sanchrPrimary)

                Toggle("Link previews", isOn: $linkPreviews)
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Font Size
            Section("Font Size") {
                ForEach(fontSizeOptions, id: \.self) { size in
                    HStack {
                        Text(size.capitalized)
                            .font(fontForSize(size))
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                        if viewModel.fontSize == size {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.fontSize = size
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Media
            Section("Media") {
                Toggle("Auto-save received media", isOn: $mediaAutoSave)
                    .tint(.sanchrPrimary)

                Text(
                    "Automatically save photos and videos received in chats to your device library."
                )
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Backup
            Section("Backup") {
                Toggle("Chat backup", isOn: $backupEnabled)
                    .tint(.sanchrPrimary)

                if backupEnabled {
                    HStack {
                        Text("Backup frequency")
                            .font(SanchrTypography.body)
                        Spacer()
                        Text("Daily")
                            .font(SanchrTypography.caption)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }

                    HStack {
                        Text("Last backup")
                            .font(SanchrTypography.body)
                        Spacer()
                        Text("Never")
                            .font(SanchrTypography.caption)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                }

                Text("Backups are end-to-end encrypted. Only you can access them.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Disappearing Messages Default
            Section("Disappearing Messages") {
                NavigationLink {
                    List {
                        ForEach(disappearingTimerOptions, id: \.1) { name, _ in
                            Text(name)
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("Default Timer")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("Default timer")
                            .font(SanchrTypography.body)
                        Spacer()
                        Text("Off")
                            .font(SanchrTypography.caption)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chat Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadSettings(settingsDataSource: settingsDataSource)
        }
    }

    // MARK: - Helpers

    private func bubbleRadius(_ style: String) -> CGFloat {
        switch style {
        case "classic": return 4
        case "compact": return 8
        default: return SanchrRadius.bubble
        }
    }

    private func fontForSize(_ size: String) -> Font {
        switch size {
        case "small": return SanchrTypography.caption
        case "large": return SanchrTypography.bodyLarge
        default: return SanchrTypography.body
        }
    }
}
