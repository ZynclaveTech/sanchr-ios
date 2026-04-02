import SwiftUI

/// Unified theme object combining all design tokens with light/dark support.
@Observable
final class SanchrTheme {
    enum Mode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var mode: Mode = .system

    /// Resolved color scheme based on current mode and system setting.
    func resolvedScheme(system: ColorScheme) -> ColorScheme {
        mode.colorScheme ?? system
    }
}

// MARK: - Theme Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = SanchrTheme()
}

extension EnvironmentValues {
    var sanchrTheme: SanchrTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Themed View Modifier

/// Applies the current theme's color scheme override to a view hierarchy.
struct ThemedModifier: ViewModifier {
    @Environment(\.sanchrTheme) private var theme
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.mode.colorScheme)
    }
}

extension View {
    func sanchrThemed() -> some View {
        modifier(ThemedModifier())
    }
}
