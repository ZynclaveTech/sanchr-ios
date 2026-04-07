import SwiftUI

/// Corner radius tokens extracted from Figma design tokens.
public enum SanchrRadius {
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let full: CGFloat = 9999

    /// Standard card/surface radius.
    public static let card: CGFloat = md

    /// Input field radius.
    public static let input: CGFloat = sm

    /// Button radius.
    public static let button: CGFloat = md

    /// Chat bubble radius.
    public static let bubble: CGFloat = lg

    /// Avatar/circle radius.
    public static let avatar: CGFloat = full

    /// Bottom sheet radius.
    public static let sheet: CGFloat = xl
}
