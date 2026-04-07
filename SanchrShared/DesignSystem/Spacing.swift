import SwiftUI

/// Spacing scale extracted from Figma design tokens.
/// Usage: `SanchrSpacing.md` or `.padding(.horizontal, SanchrSpacing.lg)`
public enum SanchrSpacing {
    public static let xxxs: CGFloat = 2
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 40
    public static let xxxxl: CGFloat = 48
    public static let mega: CGFloat = 64

    /// Standard horizontal page margin.
    public static let pageHorizontal: CGFloat = md

    /// Standard vertical section spacing.
    public static let sectionGap: CGFloat = xxl

    /// Gap between list items.
    public static let listItemGap: CGFloat = sm

    /// Inset for grouped list content.
    public static let groupedInset: CGFloat = md

    // MARK: - Chat List (Figma Exact)

    /// Avatar diameter in chat list — 56pt
    public static let chatAvatarSize: CGFloat = 56

    /// Online status indicator size — 16pt
    public static let statusIndicatorSize: CGFloat = 16

    /// Status indicator border width — 2pt
    public static let statusIndicatorBorder: CGFloat = 2

    /// Search bar height — 44pt
    public static let searchBarHeight: CGFloat = 44

    /// Search bar icon size — 15pt
    public static let searchIconSize: CGFloat = 15

    /// Filter tab height — 32pt
    public static let filterTabHeight: CGFloat = 32

    /// Filter tab horizontal padding — 16pt
    public static let filterTabHPadding: CGFloat = 16

    /// FAB size — 64pt
    public static let fabSize: CGFloat = 64

    /// FAB icon size — 20pt
    public static let fabIconSize: CGFloat = 20

    /// Tab bar height — 73pt
    public static let tabBarHeight: CGFloat = 73

    /// Chat row horizontal padding — 20pt
    public static let chatRowHPadding: CGFloat = 20

    /// Chat row vertical padding — 12pt
    public static let chatRowVPadding: CGFloat = 12

    /// Chat row min height — 80pt
    public static let chatRowHeight: CGFloat = 80

    /// Unread badge min width — 20pt
    public static let unreadBadgeSize: CGFloat = 20

    /// E2EE shield icon size — 12pt
    public static let e2eeIconSize: CGFloat = 12

    /// Avatar-to-content gap — 12pt
    public static let avatarContentGap: CGFloat = sm

    /// Name-to-preview vertical gap — 4pt
    public static let namePreviewGap: CGFloat = xxs

    /// Filter tab horizontal gap — 8pt
    public static let filterTabGap: CGFloat = xs

    /// Section header top padding — 8pt
    public static let sectionHeaderTop: CGFloat = 8

    // MARK: - Chat Screen (Export Exact)

    /// Header avatar size — 40pt
    public static let chatHeaderAvatarSize: CGFloat = 40
    /// Header avatar status dot — 12pt
    public static let chatHeaderStatusDot: CGFloat = 12
    /// Header action button size — 36pt
    public static let chatHeaderActionSize: CGFloat = 36
    /// Message bubble horizontal padding — 16pt
    public static let bubbleHPadding: CGFloat = 16
    /// Message bubble vertical padding — 10pt
    public static let bubbleVPadding: CGFloat = 10
    /// Message bubble tail radius — 4pt
    public static let bubbleTailRadius: CGFloat = 4
    /// Message bubble main radius — 20pt
    public static let bubbleMainRadius: CGFloat = 20
    /// Message max width fraction — 0.75
    public static let messageMaxWidthFraction: CGFloat = 0.75
    /// Message gap — 12pt
    public static let messageGap: CGFloat = 12
    /// Composer plus button size — 40pt
    public static let composerButtonSize: CGFloat = 40
    /// Composer send button size — 44pt
    public static let composerSendSize: CGFloat = 44
    /// Composer input border radius — 24pt
    public static let composerInputRadius: CGFloat = 24
}
