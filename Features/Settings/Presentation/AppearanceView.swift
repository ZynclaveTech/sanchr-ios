import SwiftUI
import SanchrShared

/// Theme and appearance settings screen.
/// Matches Figma: appearance-screen.
/// Syncs theme, font size, and wallpaper preferences to the backend via SettingsService.
struct AppearanceView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.sanchrTheme) private var theme
    @State private var viewModel = SettingsViewModel()
    @State private var fontStep: Double = 2
    @AppStorage("sanchr.chatBubbleStyle") private var chatBubbleStyle = "modern"
    @AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.system.rawValue
    @AppStorage("sanchr.fontSize") private var storedFontSize = "medium"

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let themeCards: [(SanchrTheme.Mode, String, String, String)] = [
        (.light, "Light Mode", "Clean and bright", "sun.max"),
        (.dark, "Dark Mode", "Easy on the eyes", "moon"),
        (.system, "System Default", "Match device settings", "circle.lefthalf.filled")
    ]

    private let bubbleOptions: [(String, String)] = [
        ("Squircle", "modern"),
        ("Rounded", "classic"),
        ("Sharp", "compact"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                themeSection
                wallpaperSection
                bubbleSection
                fontSection

                SettingsErrorLabel(message: viewModel.errorMessage)
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Appearance")
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                privacySettings: container.privacySettings
            )
            fontStep = sliderValue(for: viewModel.fontSize)
            storedFontSize = viewModel.fontSize

            if let savedMode = SanchrTheme.Mode(rawValue: storedThemeMode) {
                theme.mode = savedMode
            }

            // Hydrate the container-scoped chatAppearance with whatever
            // we just loaded from the backend so chat detail surfaces
            // pick up the wallpaper id without requiring the user to
            // re-pick it after launch.
            container.chatAppearance.setGlobal(
                wallpaperId: viewModel.chatWallpaper.isEmpty ? "default" : viewModel.chatWallpaper,
                appearanceMode: SanchrTheme.Mode(rawValue: viewModel.theme) ?? theme.mode
            )
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Theme")

            VStack(spacing: 12) {
                ForEach(themeCards, id: \.0) { mode, title, subtitle, symbol in
                    Button {
                        theme.mode = mode
                        storedThemeMode = mode.rawValue
                        viewModel.theme = mode.rawValue
                        container.chatAppearance.setGlobal(
                            wallpaperId: nil,
                            appearanceMode: mode
                        )
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    } label: {
                        HStack(spacing: 16) {
                            SettingsIconTile(
                                systemName: symbol,
                                role: theme.mode == mode ? .accent : .neutral,
                                size: 48,
                                iconSize: 18
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                Text(subtitle)
                                    .font(SanchrTypography.caption)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                            }

                            Spacer()

                            selectionIndicator(isSelected: theme.mode == mode)
                        }
                        .padding(16)
                        .settingsCard()
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.sanchrPrimary, lineWidth: theme.mode == mode ? 2 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Chat Wallpaper")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(WallpaperPainter.allWallpapers) { wp in
                    Button {
                        viewModel.chatWallpaper = wp.id
                        container.chatAppearance.setGlobal(
                            wallpaperId: wp.id,
                            appearanceMode: nil
                        )
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    } label: {
                        WallpaperPainter.background(for: wp.id)
                            .frame(height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay {
                                if viewModel.chatWallpaper == wp.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(.sanchrPrimary)
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                Text(wp.displayName)
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(wp.isDark ? .white.opacity(0.9) : SanchrExportColors.textPrimary)
                                    .padding(10)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.sanchrPrimary, lineWidth: viewModel.chatWallpaper == wp.id ? 2 : 0)
                            }
                    }
                    .buttonStyle(.plain)
                }

            }
        }
    }

    private var bubbleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Message Bubble Style")

            VStack(spacing: 12) {
                ForEach(bubbleOptions, id: \.1) { title, value in
                    Button {
                        chatBubbleStyle = value
                    } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(title)
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)

                                Spacer()

                                selectionIndicator(isSelected: chatBubbleStyle == value)
                            }

                            HStack(spacing: 8) {
                                Text("Hey there!")
                                    .font(SanchrTypography.caption)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(SanchrExportColors.surfaceMuted)
                                    .clipShape(RoundedRectangle(cornerRadius: bubbleRadius(for: value), style: .continuous))

                                Spacer(minLength: 8)

                                Text("Hello!")
                                    .font(SanchrTypography.caption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.sanchrPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: bubbleRadius(for: value), style: .continuous))
                            }
                        }
                        .padding(16)
                        .settingsCard()
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.sanchrPrimary, lineWidth: chatBubbleStyle == value ? 2 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Font Size")

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Small")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                    Spacer()
                    Text("Medium")
                        .font(SanchrTypography.caption)
                        .foregroundColor(viewModel.fontSize == "medium" ? .sanchrPrimary : SanchrExportColors.textSecondary)
                    Spacer()
                    Text("Large")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Slider(value: $fontStep, in: 1...3, step: 1)
                    .tint(.sanchrPrimary)
                    .onChange(of: fontStep) { _, newValue in
                        let newSize = fontSize(for: newValue)
                        viewModel.fontSize = newSize
                        storedFontSize = newSize
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }

                Text("This is how your messages will look with the selected font size. Adjust the slider above to find your preferred reading comfort.")
                    .font(previewFont(for: viewModel.fontSize))
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(18)
            .background(SanchrExportColors.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        SettingsSectionTitle(title: title)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Circle()
            .fill(isSelected ? Color.sanchrPrimary : .clear)
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .stroke(isSelected ? Color.sanchrPrimary : SanchrExportColors.line, lineWidth: 2)
                if isSelected {
                    Image(systemName: "checkmark")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
            }
    }

    private func sliderValue(for size: String) -> Double {
        switch size {
        case "small":
            return 1
        case "large":
            return 3
        default:
            return 2
        }
    }

    private func fontSize(for sliderValue: Double) -> String {
        switch Int(sliderValue.rounded()) {
        case 1:
            return "small"
        case 3:
            return "large"
        default:
            return "medium"
        }
    }

    private func previewFont(for size: String) -> Font {
        switch size {
        case "small":
            return SanchrTypography.caption
        case "large":
            return SanchrTypography.bodyLarge
        default:
            return SanchrTypography.body
        }
    }

    private func bubbleRadius(for style: String) -> CGFloat {
        switch style {
        case "classic":
            return SanchrSpacing.bubblePillRadius
        case "compact":
            return SanchrSpacing.bubbleCompactRadius
        default:
            return SanchrSpacing.bubbleMainRadius
        }
    }

}
