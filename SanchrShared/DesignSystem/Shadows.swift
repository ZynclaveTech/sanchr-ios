import SwiftUI

/// Shadow definitions as view modifiers for consistent elevation.
public enum SanchrShadows {
    /// Subtle shadow for cards and list items.
    public struct CardShadow: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        public init() {}

        public func body(content: Content) -> some View {
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
    public struct ElevatedShadow: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        public init() {}

        public func body(content: Content) -> some View {
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
    public struct PrimaryGlow: ViewModifier {
        public init() {}

        public func body(content: Content) -> some View {
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
    public func sanchrCardShadow() -> some View {
        modifier(SanchrShadows.CardShadow())
    }

    public func sanchrElevatedShadow() -> some View {
        modifier(SanchrShadows.ElevatedShadow())
    }

    public func sanchrPrimaryGlow() -> some View {
        modifier(SanchrShadows.PrimaryGlow())
    }
}

// MARK: - Ad hoc Shadows

private struct SanchrShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let lightOpacity: Double
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        // A black shadow at a light-mode opacity disappears against a dark
        // surface. Deepen it there so elevation still reads.
        let opacity = colorScheme == .dark ? min(lightOpacity * 4, 0.6) : lightOpacity
        return content.shadow(color: Color.black.opacity(opacity), radius: radius, x: x, y: y)
    }
}

extension View {
    /// `.shadow(color: .black.opacity(_:))` that survives dark mode. Use it
    /// wherever a card-shadow token does not fit.
    public func sanchrShadow(_ lightOpacity: Double, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(SanchrShadowModifier(lightOpacity: lightOpacity, radius: radius, x: x, y: y))
    }
}
