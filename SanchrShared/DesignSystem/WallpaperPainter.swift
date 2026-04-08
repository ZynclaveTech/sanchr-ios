import SwiftUI

/// Single source of truth for chat wallpaper IDs and their visual
/// definitions. Both the global `AppearanceView` picker and the
/// per-chat `WallpaperThemeView` picker read from `allWallpapers` so
/// the two surfaces never drift.
public enum WallpaperPainter {
    public struct Wallpaper: Identifiable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let colors: [Color]
        public let isDark: Bool
    }

    public static let allWallpapers: [Wallpaper] = [
        .init(id: "default",     displayName: "Default",     colors: [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)], isDark: false),
        .init(id: "indigo_mist", displayName: "Indigo Mist", colors: [Color(hex: 0xEEF2FF), Color(hex: 0xE0E7FF)], isDark: false),
        .init(id: "cyan_air",    displayName: "Blue Air",    colors: [Color(hex: 0xECFEFF), Color(hex: 0xCFFAFE)], isDark: false),
        .init(id: "pink_sunset", displayName: "Pink Sunset", colors: [Color(hex: 0xFDF2F8), Color(hex: 0xFCE7F3)], isDark: false),
        .init(id: "green_field", displayName: "Green Field", colors: [Color(hex: 0xF0FDF4), Color(hex: 0xDCFCE7)], isDark: false),
        .init(id: "amber_glow",  displayName: "Amber Glow",  colors: [Color(hex: 0xFFFBEB), Color(hex: 0xFEF3C7)], isDark: false),
        .init(id: "dark_indigo", displayName: "Dark Indigo", colors: [Color(hex: 0x1E1B4B), Color(hex: 0x312E81)], isDark: true),
        .init(id: "midnight",    displayName: "Midnight",    colors: [Color(hex: 0x0F172A), Color(hex: 0x1E293B)], isDark: true),
        .init(id: "deep_blue",   displayName: "Deep Blue",   colors: [Color(hex: 0x1A1A2E), Color(hex: 0x16213E)], isDark: true),
    ]

    /// Returns the wallpaper matching `id`, or the default wallpaper as
    /// a graceful fallback if the id isn't in the registry.
    public static func wallpaper(for id: String) -> Wallpaper {
        allWallpapers.first(where: { $0.id == id }) ?? allWallpapers[0]
    }

    /// SwiftUI background view for the given wallpaper id. Always
    /// returns a `LinearGradient` because every wallpaper in the
    /// registry is gradient-based.
    public static func background(for id: String) -> some View {
        let wp = wallpaper(for: id)
        return LinearGradient(
            colors: wp.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// View modifier that paints a wallpaper as the background of a chat
/// surface. Ignores safe area so the gradient extends behind the nav
/// bar and home indicator.
public struct ChatBackgroundModifier: ViewModifier {
    let wallpaperId: String
    public init(wallpaperId: String) { self.wallpaperId = wallpaperId }
    public func body(content: Content) -> some View {
        content.background(WallpaperPainter.background(for: wallpaperId).ignoresSafeArea())
    }
}

public extension View {
    /// Paint a chat wallpaper behind this view. Use the wallpaper id
    /// from the global setting or per-chat override; unknown ids fall
    /// back to the default wallpaper via `WallpaperPainter.wallpaper(for:)`.
    func chatBackground(wallpaperId: String) -> some View {
        modifier(ChatBackgroundModifier(wallpaperId: wallpaperId))
    }
}
