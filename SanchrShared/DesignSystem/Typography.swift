import SwiftUI

/// Typography scale extracted from Figma design tokens.
/// The exported HTML uses Afacad as the visible family across screens.
public enum SanchrTypography {
    // MARK: - Font Sizes

    public enum Size: CGFloat {
        case xxxs = 10
        case xxs = 12
        case xs = 14
        case sm = 16
        case md = 18
        case lg = 20
        case xl = 24
        case xxl = 30
        case display = 36
        case hero = 48
    }

    // MARK: - Font Weights

    public enum Weight {
        case regular
        case medium
        case semibold
        case bold

        public var swiftUIWeight: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }

        public var uiKitWeight: UIFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    // MARK: - Semantic Styles

    public static func primary(size: Size, weight: Weight = .regular) -> Font {
        font(size: size, weight: weight)
    }

    public static func secondary(size: Size, weight: Weight = .regular) -> Font {
        font(size: size, weight: weight)
    }

    /// Whether the bundled Afacad family is registered (via `UIAppFonts` in
    /// the app's Info.plist). Resolved once: this used to be a CoreText
    /// lookup on every font access, which is every view body.
    ///
    /// Checked by family, not `UIFont(name: "Afacad")`: that takes a
    /// PostScript name, and the variable file's is "Afacad-Regular", so the
    /// old check was false even once the font was registered.
    private static let afacadIsRegistered = !UIFont.fontNames(forFamilyName: "Afacad").isEmpty

    public static func font(size: Size, weight: Weight = .regular) -> Font {
        let pointSize = size.rawValue
        // Apply Dynamic Type scaling — fonts scale with system text size preference.
        // Users with vision impairment who increase text size in Settings will see larger fonts.
        // SwiftUI's `Font.custom(_:size:relativeTo:)` and `.system(_:design:weight:)` tie a
        // font to a text style so the point size scales with the user's Dynamic Type preference.
        if afacadIsRegistered {
            return .custom("Afacad", size: pointSize, relativeTo: .body)
                .weight(weight.swiftUIWeight)
        } else {
            return .system(size: pointSize, weight: weight.swiftUIWeight, design: .rounded)
        }
    }

    /// Large hero text (48pt bold primary).
    public static let heroTitle = primary(size: .hero, weight: .bold)

    /// Screen titles (30pt semibold primary).
    public static let screenTitle = primary(size: .xxl, weight: .semibold)

    /// Export hero title (36pt semibold primary).
    public static let displayTitle = primary(size: .display, weight: .semibold)

    /// Section headers (24pt semibold primary).
    public static let sectionHeader = primary(size: .xl, weight: .semibold)

    /// Card/list titles (20pt semibold primary).
    public static let cardTitle = primary(size: .lg, weight: .semibold)

    /// Body large (18pt medium).
    public static let bodyLarge = secondary(size: .md, weight: .medium)

    /// Body default (16pt medium).
    public static let body = secondary(size: .sm, weight: .medium)

    /// Body bold (16pt semibold secondary).
    public static let bodyBold = secondary(size: .sm, weight: .semibold)

    /// Caption (14pt regular secondary).
    public static let caption = secondary(size: .xs, weight: .regular)

    /// Small caption (12pt regular secondary).
    public static let captionSmall = secondary(size: .xxs, weight: .regular)

    /// Micro text (10pt regular secondary).
    public static let micro = secondary(size: .xxxs, weight: .regular)

    /// Button text (16pt semibold primary).
    public static let button = primary(size: .sm, weight: .semibold)

    /// Tab bar label (12pt semibold).
    public static let tabLabel = secondary(size: .xxs, weight: .semibold)

    /// Chat message text (16pt medium).
    public static let chatMessage = secondary(size: .sm, weight: .medium)

    /// Message bubble text — Afacad 14pt medium
    public static let messageBubbleText = secondary(size: .xs, weight: .medium)

    /// Message timestamp external — Afacad 12pt regular
    public static let messageTimestamp = secondary(size: .xxs, weight: .regular)

    /// Chat timestamp — Afacad 12pt medium
    public static let chatTimestamp = secondary(size: .xxs, weight: .medium)

    /// Search placeholder — Afacad 14pt medium
    public static let searchPlaceholder = secondary(size: .xs, weight: .medium)

    // MARK: - Chat List Figma Styles

    /// Chat list header title — Afacad 24pt bold
    public static let chatListTitle = primary(size: .xl, weight: .bold)

    /// Conversation name — Afacad 16pt semibold, -0.5 tracking
    public static let conversationName = primary(size: .sm, weight: .semibold)

    /// Conversation preview — Afacad 14pt medium
    public static let conversationPreview = secondary(size: .xs, weight: .medium)

    /// Conversation preview bold (unread) — Afacad 14pt semibold
    public static let conversationPreviewBold = secondary(size: .xs, weight: .semibold)

    /// Filter tab label — Afacad 14pt semibold
    public static let filterTab = secondary(size: .xs, weight: .semibold)

    /// Filter tab label active — Afacad 14pt bold
    public static let filterTabActive = secondary(size: .xs, weight: .bold)

    /// Pinned section label — Afacad 12pt semibold, all caps
    public static let sectionLabel = secondary(size: .xxs, weight: .semibold)

    /// Unread badge count — Afacad 12pt bold
    public static let unreadBadge = secondary(size: .xxs, weight: .bold)

    /// E2EE badge text — Afacad 10pt medium
    public static let e2eeBadge = secondary(size: .xxxs, weight: .medium)

    // MARK: - Tracking Values (Letter Spacing)

    public static let conversationNameTracking: CGFloat = -0.5

    public static let sectionLabelTracking: CGFloat = 0.5
}
