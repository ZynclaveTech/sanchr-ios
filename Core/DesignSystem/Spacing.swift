import SwiftUI

/// Spacing scale extracted from Figma design tokens.
/// Usage: `SanchrSpacing.md` or `.padding(.horizontal, SanchrSpacing.lg)`
enum SanchrSpacing {
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
    static let xxxxl: CGFloat = 48
    static let mega: CGFloat = 64

    /// Standard horizontal page margin.
    static let pageHorizontal: CGFloat = md

    /// Standard vertical section spacing.
    static let sectionGap: CGFloat = xxl

    /// Gap between list items.
    static let listItemGap: CGFloat = sm

    /// Inset for grouped list content.
    static let groupedInset: CGFloat = md
}
