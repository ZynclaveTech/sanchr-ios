import SwiftUI

/// Typography scale extracted from Figma design tokens.
/// Primary: Afacad, Secondary: Inter, Fallback: system fonts.
enum SanchrTypography {
    // MARK: - Font Names

    private static let primaryFamily = "Afacad"
    private static let secondaryFamily = "Inter"

    // MARK: - Font Sizes

    enum Size: CGFloat {
        case xxxs = 10
        case xxs = 12
        case xs = 14
        case sm = 16
        case md = 18
        case lg = 20
        case xl = 24
        case xxl = 30
        case hero = 48
    }

    // MARK: - Font Weights

    enum Weight {
        case regular
        case medium
        case semibold
        case bold

        var swiftUIWeight: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }

        var primarySuffix: String {
            switch self {
            case .regular: "-Regular"
            case .medium: "-Medium"
            case .semibold: "-SemiBold"
            case .bold: "-Bold"
            }
        }

        var secondarySuffix: String {
            switch self {
            case .regular: "-Regular"
            case .medium: "-Medium"
            case .semibold: "-SemiBold"
            case .bold: "-Bold"
            }
        }
    }

    // MARK: - Font Builders

    /// Creates a primary (Afacad) font with fallback to system rounded.
    static func primary(size: Size, weight: Weight = .regular) -> Font {
        let fontName = "\(primaryFamily)\(weight.primarySuffix)"
        if UIFont(name: fontName, size: size.rawValue) != nil {
            return .custom(fontName, size: size.rawValue)
        }
        return .system(size: size.rawValue, weight: weight.swiftUIWeight, design: .rounded)
    }

    /// Creates a secondary (Inter) font with fallback to system default.
    static func secondary(size: Size, weight: Weight = .regular) -> Font {
        let fontName = "\(secondaryFamily)\(weight.secondarySuffix)"
        if UIFont(name: fontName, size: size.rawValue) != nil {
            return .custom(fontName, size: size.rawValue)
        }
        return .system(size: size.rawValue, weight: weight.swiftUIWeight, design: .default)
    }

    // MARK: - Semantic Styles

    /// Large hero text (48pt bold primary).
    static let heroTitle = primary(size: .hero, weight: .bold)

    /// Screen titles (30pt bold primary).
    static let screenTitle = primary(size: .xxl, weight: .bold)

    /// Section headers (24pt semibold primary).
    static let sectionHeader = primary(size: .xl, weight: .semibold)

    /// Card/list titles (20pt semibold primary).
    static let cardTitle = primary(size: .lg, weight: .semibold)

    /// Body large (18pt regular secondary).
    static let bodyLarge = secondary(size: .md, weight: .regular)

    /// Body default (16pt regular secondary).
    static let body = secondary(size: .sm, weight: .regular)

    /// Body bold (16pt semibold secondary).
    static let bodyBold = secondary(size: .sm, weight: .semibold)

    /// Caption (14pt regular secondary).
    static let caption = secondary(size: .xs, weight: .regular)

    /// Small caption (12pt regular secondary).
    static let captionSmall = secondary(size: .xxs, weight: .regular)

    /// Micro text (10pt regular secondary).
    static let micro = secondary(size: .xxxs, weight: .regular)

    /// Button text (16pt semibold primary).
    static let button = primary(size: .sm, weight: .semibold)

    /// Tab bar label (12pt medium secondary).
    static let tabLabel = secondary(size: .xxs, weight: .medium)

    /// Chat message text (16pt regular secondary).
    static let chatMessage = secondary(size: .sm, weight: .regular)

    /// Chat timestamp (12pt regular secondary).
    static let chatTimestamp = secondary(size: .xxs, weight: .regular)
}
