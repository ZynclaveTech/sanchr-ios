import SwiftUI

/// Design tokens for color extracted from Figma.
/// All colors are available as `Color.sanchr*` extensions.
public enum SanchrColors {
    // MARK: - Brand

    public static let primary = Color(hex: 0x6366F1)  // Indigo
    public static let primaryDark = Color(hex: 0x4C1D95)  // Dark Indigo
    public static let accent = Color(hex: 0x06B6D4)  // Cyan

    // MARK: - Semantic

    public static let success = Color(hex: 0x22C55E)
    public static let error = Color(hex: 0xEF4444)
    public static let warning = Color(hex: 0xF59E0B)
    public static let info = Color(hex: 0x3B82F6)

    // MARK: - Neutral (Light Mode)

    public static let backgroundLight = Color(hex: 0xFFFFFF)
    public static let surfaceLight = Color(hex: 0xF9FAFB)
    public static let surfaceElevatedLight = Color(hex: 0xFFFFFF)
    public static let textPrimaryLight = Color(hex: 0x111827)
    public static let textSecondaryLight = Color(hex: 0x6B7280)
    public static let textTertiaryLight = Color(hex: 0x9CA3AF)
    public static let borderLight = Color(hex: 0xE5E7EB)
    public static let dividerLight = Color(hex: 0xF3F4F6)

    // MARK: - Neutral (Dark Mode)

    public static let backgroundDark = Color(hex: 0x0F0F14)
    public static let surfaceDark = Color(hex: 0x1A1A24)
    public static let surfaceElevatedDark = Color(hex: 0x24243A)
    public static let textPrimaryDark = Color(hex: 0xF9FAFB)
    public static let textSecondaryDark = Color(hex: 0x9CA3AF)
    public static let textTertiaryDark = Color(hex: 0x6B7280)
    public static let borderDark = Color(hex: 0x2D2D3F)
    public static let dividerDark = Color(hex: 0x1F1F2E)

    // MARK: - Chat Bubbles

    public static let bubbleSent = Color(hex: 0x6366F1)
    public static let bubbleReceived = Color(hex: 0x1F1F2E)
    public static let bubbleSentText = Color.white
    public static let bubbleReceivedText = Color(hex: 0xF9FAFB)

    // MARK: - Encryption Badge

    public static let encryptionBadge = Color(hex: 0x22C55E).opacity(0.15)
    public static let encryptionBadgeText = Color(hex: 0x22C55E)

    // MARK: - Chat List (Figma Exact)

    /// Search bar / filter tab background — Figma #F3F4F6
    public static let searchBackgroundLight = Color(hex: 0xF3F4F6)
    public static let searchBackgroundDark = Color(hex: 0x1F1F2E)

    /// Filter chip inactive background — same as search bg
    public static let chipInactiveLight = Color(hex: 0xF3F4F6)
    public static let chipInactiveDark = Color(hex: 0x1F1F2E)

    /// Avatar border color
    public static let avatarBorderLight = Color.white
    public static let avatarBorderDark = Color(hex: 0x24243A)

    /// Group message sender name — Figma #374151
    public static let groupSenderLight = Color(hex: 0x374151)
    public static let groupSenderDark = Color(hex: 0xD1D5DB)

    /// Message preview text — Figma #4B5563
    public static let previewTextLight = Color(hex: 0x4B5563)
    public static let previewTextDark = Color(hex: 0x9CA3AF)

    // MARK: - Presence Status

    /// Online indicator — Figma #22C55E
    public static let statusOnline = Color(hex: 0x22C55E)
    /// Away/idle indicator — Figma #FACC15
    public static let statusAway = Color(hex: 0xFACC15)
    /// Offline indicator — Figma #D1D5DB
    public static let statusOffline = Color(hex: 0xD1D5DB)
    /// Do-not-disturb indicator
    public static let statusDND = Color(hex: 0xEF4444)

    // MARK: - Group Avatar Gradients (Figma Exact)

    public static let groupGradientBlue = (Color(hex: 0x3B82F6), Color(hex: 0x1D4ED8))
    public static let groupGradientPurple = (Color(hex: 0x8B5CF6), Color(hex: 0x6D28D9))
    public static let groupGradientPink = (Color(hex: 0xEC4899), Color(hex: 0xBE185D))
    public static let groupGradientTeal = (Color(hex: 0x14B8A6), Color(hex: 0x0D9488))

    // MARK: - Chat Screen (Export Exact)

    /// E2E banner gradient start — cyan/10
    public static let e2eBannerStartLight = Color(hex: 0x06B6D4).opacity(0.1)
    public static let e2eBannerStartDark = Color(hex: 0x06B6D4).opacity(0.15)
    /// E2E banner gradient end — indigo/10
    public static let e2eBannerEndLight = Color(hex: 0x6366F1).opacity(0.1)
    public static let e2eBannerEndDark = Color(hex: 0x6366F1).opacity(0.15)
    /// E2E banner border — cyan/20
    public static let e2eBannerBorder = Color(hex: 0x06B6D4).opacity(0.2)
    /// Received bubble border — gray-100
    public static let receivedBubbleBorderLight = Color(hex: 0xF3F4F6)
    public static let receivedBubbleBorderDark = Color(hex: 0x2D2D3F)
    /// Security event amber colors
    public static let securityEventBg = Color(hex: 0xFFFBEB)
    public static let securityEventBorder = Color(hex: 0xFDE68A)
    public static let securityEventText = Color(hex: 0xB45309)
    public static let securityEventIcon = Color(hex: 0xD97706)
}

// MARK: - Color Extension

extension Color {
    public static let sanchrPrimary = SanchrColors.primary
    public static let sanchrPrimaryDark = SanchrColors.primaryDark
    public static let sanchrAccent = SanchrColors.accent
    public static let sanchrSuccess = SanchrColors.success
    public static let sanchrError = SanchrColors.error
    public static let sanchrWarning = SanchrColors.warning
    public static let sanchrInfo = SanchrColors.info

    // MARK: - Adaptive Colors

    /// Background color that adapts to the current color scheme.
    public static func sanchrBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.backgroundDark : SanchrColors.backgroundLight
    }

    public static func sanchrSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.surfaceDark : SanchrColors.surfaceLight
    }

    public static func sanchrSurfaceElevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.surfaceElevatedDark : SanchrColors.surfaceElevatedLight
    }

    public static func sanchrTextPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.textPrimaryDark : SanchrColors.textPrimaryLight
    }

    public static func sanchrTextSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.textSecondaryDark : SanchrColors.textSecondaryLight
    }

    public static func sanchrTextTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.textTertiaryDark : SanchrColors.textTertiaryLight
    }

    public static func sanchrBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.borderDark : SanchrColors.borderLight
    }

    public static func sanchrDivider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.dividerDark : SanchrColors.dividerLight
    }

    public static func sanchrSearchBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.searchBackgroundDark : SanchrColors.searchBackgroundLight
    }

    public static func sanchrPreviewText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.previewTextDark : SanchrColors.previewTextLight
    }

    public static func sanchrChipInactive(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.chipInactiveDark : SanchrColors.chipInactiveLight
    }

    public static func sanchrAvatarBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.avatarBorderDark : SanchrColors.avatarBorderLight
    }

    public static func sanchrGroupSender(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? SanchrColors.groupSenderDark : SanchrColors.groupSenderLight
    }
}

// MARK: - Hex Initializer

extension Color {
    public init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
