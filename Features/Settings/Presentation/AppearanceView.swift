import SwiftUI

/// Theme and appearance settings screen.
/// Matches Figma: appearance-screen.
/// Syncs theme, font size, and wallpaper preferences to the backend via SettingsService.
struct AppearanceView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.sanchrTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = SettingsViewModel()

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let fontSizeOptions = ["small", "medium", "large"]

    private let wallpaperOptions = [
        ("Default", ""),
        ("Dark Gradient", "dark_gradient"),
        ("Subtle Pattern", "subtle_pattern"),
        ("Minimal", "minimal"),
        ("Nature", "nature"),
    ]

    var body: some View {
        List {
            // MARK: - Theme Picker
            Section("Theme") {
                ForEach(SanchrTheme.Mode.allCases) { mode in
                    HStack {
                        // Theme preview circle
                        Circle()
                            .fill(themePreviewColor(for: mode))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .stroke(Color.sanchrBorder(colorScheme), lineWidth: 1)
                            )

                        Text(mode.displayName)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                        Spacer()

                        if theme.mode == mode {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                                .font(.body.bold())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        theme.mode = mode
                        viewModel.theme = mode.rawValue
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
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

            // MARK: - Chat Wallpaper
            Section("Chat Wallpaper") {
                ForEach(wallpaperOptions, id: \.1) { name, value in
                    HStack {
                        RoundedRectangle(cornerRadius: SanchrRadius.sm)
                            .fill(wallpaperPreviewColor(value))
                            .frame(width: 40, height: 40)

                        Text(name)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                        Spacer()

                        if viewModel.chatWallpaper == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.chatWallpaper = value
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadSettings(settingsDataSource: settingsDataSource)
        }
    }

    // MARK: - Helpers

    private func themePreviewColor(for mode: SanchrTheme.Mode) -> Color {
        switch mode {
        case .light: return .white
        case .dark: return Color(hex: 0x0F0F14)
        case .system: return Color.sanchrPrimary.opacity(0.3)
        }
    }

    private func fontForSize(_ size: String) -> Font {
        switch size {
        case "small": return SanchrTypography.caption
        case "large": return SanchrTypography.bodyLarge
        default: return SanchrTypography.body
        }
    }

    private func wallpaperPreviewColor(_ value: String) -> Color {
        switch value {
        case "dark_gradient": return Color(hex: 0x1A1A24)
        case "subtle_pattern": return Color(hex: 0xE5E7EB)
        case "minimal": return Color(hex: 0xF9FAFB)
        case "nature": return Color(hex: 0x22C55E).opacity(0.3)
        default: return Color.sanchrSurface(colorScheme)
        }
    }
}
