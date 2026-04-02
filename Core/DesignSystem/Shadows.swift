import SwiftUI

/// Shadow definitions as view modifiers for consistent elevation.
enum SanchrShadows {
    /// Subtle shadow for cards and list items.
    struct CardShadow: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            content.shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.3)
                    : Color.black.opacity(0.06),
                radius: 8,
                x: 0,
                y: 2
            )
        }
    }

    /// Elevated shadow for floating elements (FABs, sheets).
    struct ElevatedShadow: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        func body(content: Content) -> some View {
            content.shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.5)
                    : Color.black.opacity(0.12),
                radius: 16,
                x: 0,
                y: 4
            )
        }
    }

    /// Glow effect for primary action buttons.
    struct PrimaryGlow: ViewModifier {
        func body(content: Content) -> some View {
            content.shadow(
                color: SanchrColors.primary.opacity(0.4),
                radius: 12,
                x: 0,
                y: 4
            )
        }
    }
}

// MARK: - View Extensions

extension View {
    func sanchrCardShadow() -> some View {
        modifier(SanchrShadows.CardShadow())
    }

    func sanchrElevatedShadow() -> some View {
        modifier(SanchrShadows.ElevatedShadow())
    }

    func sanchrPrimaryGlow() -> some View {
        modifier(SanchrShadows.PrimaryGlow())
    }
}
