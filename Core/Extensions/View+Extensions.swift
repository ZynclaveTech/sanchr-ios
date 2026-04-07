import SwiftUI
import SanchrShared

// MARK: - Common View Modifiers

extension View {
    /// Applies the standard Sanchr screen background.
    func sanchrScreenBackground() -> some View {
        modifier(ScreenBackgroundModifier())
    }

    /// Applies a standard card style with surface color, radius, and shadow.
    func sanchrCard() -> some View {
        modifier(CardModifier())
    }

    /// Conditionally applies a view modifier.
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Hides the view completely (removes from layout).
    @ViewBuilder
    func hidden(_ isHidden: Bool) -> some View {
        if !isHidden {
            self
        }
    }

    /// Reads the view's geometry and reports its size via a binding.
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: SizePreferenceKey.self, value: geometry.size)
            }
        )
        .onPreferenceChange(SizePreferenceKey.self, perform: onChange)
    }
}

// MARK: - Modifiers

private struct ScreenBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.sanchrBackground(colorScheme))
    }
}

private struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(SanchrSpacing.md)
            .background(Color.sanchrSurfaceElevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
            .sanchrCardShadow()
    }
}

// MARK: - Preference Keys

private struct SizePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
