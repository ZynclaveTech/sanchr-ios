import SwiftUI

/// Unified theme object combining all design tokens with light/dark support.
@Observable
public final class SanchrTheme: @unchecked Sendable {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        public var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// Follows the device until the user chooses. A forced light default
    /// meant every dark-mode user got a white app on first launch.
    public var mode: Mode = .system

    public init() {}

    /// Resolved color scheme based on current mode and system setting.
    public func resolvedScheme(system: ColorScheme) -> ColorScheme {
        mode.colorScheme ?? system
    }
}

// MARK: - Theme Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = SanchrTheme()
}

extension EnvironmentValues {
    public var sanchrTheme: SanchrTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Themed View Modifier

/// Applies the current theme's color scheme override to a view hierarchy.
public struct ThemedModifier: ViewModifier {
    @Environment(\.sanchrTheme) private var theme
    @Environment(\.colorScheme) private var systemScheme

    public init() {}

    public func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.mode.colorScheme)
    }
}

extension View {
    public func sanchrThemed() -> some View {
        modifier(ThemedModifier())
    }
}
