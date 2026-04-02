import SwiftUI

/// Design tokens for color extracted from Figma.
/// All colors are available as `Color.sanchr*` extensions.
enum SanchrColors {
    // MARK: - Brand

    static let primary = Color(hex: 0x6366F1)       // Indigo
    static let primaryDark = Color(hex: 0x4C1D95)   // Dark Indigo
    static let accent = Color(hex: 0x06B6D4)         // Cyan

    // MARK: - Semantic

    static let success = Color(hex: 0x22C55E)
    static let error = Color(hex: 0xEF4444)
    static let warning = Color(hex: 0xF59E0B)
    static let info = Color(hex: 0x3B82F6)

    // MARK: - Neutral (Light Mode)

    static let backgroundLight = Color(hex: 0xFFFFFF)
    static let surfaceLight = Color(hex: 0xF9FAFB)
    static let surfaceElevatedLight = Color(hex: 0xFFFFFF)
    static let textPrimaryLight = Color(hex: 0x111827)
    static let textSecondaryLight = Color(hex: 0x6B7280)
    static let textTertiaryLight = Color(hex: 0x9CA3AF)
    static let borderLight = Color(hex: 0xE5E7EB)
    static let dividerLight = Color(hex: 0xF3F4F6)

    // MARK: - Neutral (Dark Mode)

    static let backgroundDark = Color(hex: 0x0F0F14)
    static let surfaceDark = Color(hex: 0x1A1A24)
    static let surfaceElevatedDark = Color(hex: 0x24243A)
    static let textPrimaryDark = Color(hex: 0xF9FAFB)
    static let textSecondaryDark = Color(hex: 0x9CA3AF)
    static let textTertiaryDark = Color(hex: 0x6B7280)
    static let borderDark = Color(hex: 0x2D2D3F)
    static let dividerDark = Color(hex: 0x1F1F2E)

    // MARK: - Chat Bubbles

    static let bubbleSent = Color(hex: 0x6366F1)
    static let bubbleReceived = Color(hex: 0x1F1F2E)
    static let bubbleSentText = Color.white
    static let bubbleReceivedText = Color(hex: 0xF9FAFB)

    // MARK: - Encryption Badge

    static let encryptionBadge = Color(hex: 0x22C55E).opacity(0.15)
    static let encryptionBadgeText = Color(hex: 0x22C55E)
}

// MARK: - Color Extension

extension Color {
    static let sanchrPrimary = SanchrColors.primary
    static let sanchrPrimaryDark = SanchrColors.primaryDark
    static let sanchrAccent = SanchrColors.accent
    static let sanchrSuccess = SanchrColors.success
    static let sanchrError = SanchrColors.error
    static let sanchrWarning = SanchrColors.warning
    static let sanchrInfo = SanchrColors.info

    // MARK: - Adaptive Colors

    /// Background color that adapts to the current color scheme.
    static func sanchrBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.backgroundDark : SanchrColors.backgroundLight
    }

    static func sanchrSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.surfaceDark : SanchrColors.surfaceLight
    }

    static func sanchrSurfaceElevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.surfaceElevatedDark : SanchrColors.surfaceElevatedLight
    }

    static func sanchrTextPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.textPrimaryDark : SanchrColors.textPrimaryLight
    }

    static func sanchrTextSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.textSecondaryDark : SanchrColors.textSecondaryLight
    }

    static func sanchrTextTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.textTertiaryDark : SanchrColors.textTertiaryLight
    }

    static func sanchrBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.borderDark : SanchrColors.borderLight
    }

    static func sanchrDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.dividerDark : SanchrColors.dividerLight
    }
}

// MARK: - Hex Initializer

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
