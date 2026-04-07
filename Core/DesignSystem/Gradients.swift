import SwiftUI
import SanchrShared

/// Gradient definitions extracted from Figma design tokens.
enum SanchrGradients {
    /// Primary brand gradient (indigo to cyan).
    static let primary = LinearGradient(
        colors: [SanchrColors.primary, SanchrColors.accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Dark brand gradient (dark indigo to indigo).
    static let primaryDark = LinearGradient(
        colors: [SanchrColors.primaryDark, SanchrColors.primary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Call button gradient (green success tones).
    static let callAccept = LinearGradient(
        colors: [SanchrColors.success, Color(hex: 0x16A34A)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// End call gradient (red error tones).
    static let callDecline = LinearGradient(
        colors: [SanchrColors.error, Color(hex: 0xDC2626)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Subtle surface gradient for card backgrounds (dark mode).
    static let surfaceDark = LinearGradient(
        colors: [
            Color(hex: 0x1A1A24),
            Color(hex: 0x0F0F14),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Encryption badge shimmer gradient.
    static let encryptionShimmer = LinearGradient(
        colors: [
            SanchrColors.success.opacity(0.1),
            SanchrColors.success.opacity(0.3),
            SanchrColors.success.opacity(0.1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}
