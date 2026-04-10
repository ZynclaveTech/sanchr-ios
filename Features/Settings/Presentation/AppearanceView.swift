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
    @AppStorage("sanchr.accentColor") private var accentColorID = "indigo"
    @AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.light.rawValue

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let themeCards: [(SanchrTheme.Mode, String, String, [Color], String)] = [
        (.light, "Light Mode", "Clean and bright", [Color.white, Color(hex: 0xF3F4F6)], "sun.max.fill"),
        (.dark, "Dark Mode", "Easy on the eyes", [Color(hex: 0x0F172A), Color(hex: 0x111827)], "moon.fill"),
        (.system, "System Default", "Match device settings", [Color.white, Color(hex: 0xCBD5E1), Color(hex: 0x0F172A)], "circle.lefthalf.filled")
    ]

    private let wallpaperOptions: [(String, String)] = [
        ("Default", ""),
        ("Indigo Mist", "subtle_pattern"),
        ("Blue Air", "minimal"),
        ("Midnight", "dark_gradient"),
        ("Nature", "nature"),
    ]

    private let bubbleOptions: [(String, String)] = [
        ("Squircle", "modern"),
        ("Rounded", "classic"),
        ("Sharp", "compact"),
    ]

    private let accentOptions: [(String, Color)] = [
        ("indigo", SanchrColors.primary),
        ("violet", Color(hex: 0x4C1D95)),
        ("cyan", SanchrColors.accent),
        ("blue", Color(hex: 0x3B82F6)),
        ("emerald", Color(hex: 0x10B981)),
        ("pink", Color(hex: 0xEC4899)),
        ("orange", Color(hex: 0xF97316)),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                themeSection
                sanchrModeSection
                wallpaperSection
                bubbleSection
                accentSection
                fontSection
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
                ForEach(themeCards, id: \.0) { mode, title, subtitle, colors, symbol in
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
                                    Image(systemName: symbol)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(mode == .light ? .yellow : .white)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(mode == .light ? Color(hex: 0xE5E7EB) : .clear, lineWidth: 1)
                                }

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
                        .background(SanchrExportColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(theme.mode == mode ? SanchrColors.primary : Color(hex: 0xE5E7EB), lineWidth: theme.mode == mode ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sanchrModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Sanchr Mode")

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SanchrColors.primaryDark, SanchrColors.primary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sanchr Mode")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text("Enhanced privacy mode")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }

                    Spacer()

                    Toggle("", isOn: $viewModel.vyncModeEnabled)
                        .labelsHidden()
                        .tint(.sanchrPrimary)
                        .onChange(of: viewModel.vyncModeEnabled) { _, newValue in
                            Task {
                                await viewModel.setVyncMode(enabled: newValue, settingsDataSource: settingsDataSource)
                            }
                        }
                }

                Text("When enabled, previews stay hidden and the app shifts to a more discreet privacy posture.")
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
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
                                    .stroke(viewModel.chatWallpaper == wp.id ? SanchrColors.primary : Color(hex: 0xE5E7EB), lineWidth: viewModel.chatWallpaper == wp.id ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                }

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SanchrExportColors.surface)
                    .frame(height: 108)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(SanchrExportColors.textTertiary)
                            Text("More")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(hex: 0xE5E7EB), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
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
                                    .background(
                                        LinearGradient(
                                            colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: bubbleRadius(for: value), style: .continuous))
                            }
                        }
                        .padding(16)
                        .background(SanchrExportColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(chatBubbleStyle == value ? SanchrColors.primary : Color(hex: 0xE5E7EB), lineWidth: chatBubbleStyle == value ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Accent Color")

            HStack(spacing: 12) {
                ForEach(accentOptions, id: \.0) { id, color in
                    Button {
                        accentColorID = id
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 48, height: 48)
                            .overlay {
                                if accentColorID == id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .overlay {
                                Circle()
                                    .stroke(Color.white, lineWidth: accentColorID == id ? 4 : 0)
                            }
                            .shadow(color: accentColorID == id ? color.opacity(0.28) : .clear, radius: 12, x: 0, y: 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SanchrTypography.sectionLabel)
            .tracking(1.2)
            .foregroundColor(SanchrExportColors.textSecondary)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Circle()
            .fill(isSelected ? SanchrColors.primary : .clear)
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .stroke(isSelected ? SanchrColors.primary : Color(hex: 0xD1D5DB), lineWidth: 2)
                if isSelected {
                    Image(systemName: "checkmark")
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
            return 999
        case "compact":
            return 10
        default:
            return 20
        }
    }

    private func wallpaperGradient(for value: String) -> LinearGradient {
        switch value {
        case "dark_gradient":
            return LinearGradient(colors: [Color(hex: 0x1E1B4B), Color(hex: 0x0F172A)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "subtle_pattern":
            return LinearGradient(colors: [Color(hex: 0xE0E7FF), Color(hex: 0xF5F3FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "minimal":
            return LinearGradient(colors: [Color(hex: 0xECFEFF), Color(hex: 0xDBEAFE)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "nature":
            return LinearGradient(colors: [Color(hex: 0xDCFCE7), Color(hex: 0xBBF7D0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [Color.white, Color(hex: 0xF8FAFC)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
