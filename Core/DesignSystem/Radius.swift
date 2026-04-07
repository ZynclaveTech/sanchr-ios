import SwiftUI
import SanchrShared

/// Corner radius tokens extracted from Figma design tokens.
enum SanchrRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let full: CGFloat = 9999

    /// Standard card/surface radius.
    static let card: CGFloat = md

    /// Input field radius.
    static let input: CGFloat = sm

    /// Button radius.
    static let button: CGFloat = md

    /// Chat bubble radius.
    static let bubble: CGFloat = lg

    /// Avatar/circle radius.
    static let avatar: CGFloat = full

    /// Bottom sheet radius.
    static let sheet: CGFloat = xl
}
