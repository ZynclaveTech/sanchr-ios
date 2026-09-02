import SanchrShared
import SwiftUI

/// What the transcript is drawn over.
///
/// Timestamps, receipts and the date chip sit directly on the chat
/// background rather than inside a bubble, so their colours have to follow
/// the wallpaper's luminance, not the colour scheme. A dark wallpaper in
/// light theme resolved them to translucent black on indigo; a light
/// wallpaper in dark theme to translucent white on pastel. Both invisible.
enum TranscriptGround: Equatable {
    /// The default surface, which follows the colour scheme.
    case system
    case lightWallpaper
    case darkWallpaper

    static func forWallpaper(id: String) -> TranscriptGround {
        guard id != "default",
              let wallpaper = WallpaperPainter.allWallpapers.first(where: { $0.id == id })
        else { return .system }
        return wallpaper.isDark ? .darkWallpaper : .lightWallpaper
    }

    var timestampColor: Color {
        switch self {
        case .system: SanchrExportColors.textTertiary
        case .lightWallpaper: Color.black.opacity(0.55)
        case .darkWallpaper: Color.white.opacity(0.78)
        }
    }

    var chipBackground: Color {
        switch self {
        case .system: SanchrExportColors.surface
        case .lightWallpaper: Color.white.opacity(0.85)
        case .darkWallpaper: Color.black.opacity(0.35)
        }
    }

    var chipText: Color {
        switch self {
        case .system: SanchrExportColors.textSecondary
        case .lightWallpaper: Color.black.opacity(0.7)
        case .darkWallpaper: Color.white.opacity(0.92)
        }
    }

    var chipStroke: Color {
        switch self {
        case .system: SanchrExportColors.line
        case .lightWallpaper: Color.black.opacity(0.08)
        case .darkWallpaper: Color.white.opacity(0.14)
        }
    }
}

private struct TranscriptGroundKey: EnvironmentKey {
    static let defaultValue: TranscriptGround = .system
}

extension EnvironmentValues {
    var transcriptGround: TranscriptGround {
        get { self[TranscriptGroundKey.self] }
        set { self[TranscriptGroundKey.self] = newValue }
    }
}
