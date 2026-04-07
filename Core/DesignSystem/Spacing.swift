import SwiftUI
import SanchrShared

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

    // MARK: - Chat List (Figma Exact)

    /// Avatar diameter in chat list — 56pt
    static let chatAvatarSize: CGFloat = 56

    /// Online status indicator size — 16pt
    static let statusIndicatorSize: CGFloat = 16

    /// Status indicator border width — 2pt
    static let statusIndicatorBorder: CGFloat = 2

    /// Search bar height — 44pt
    static let searchBarHeight: CGFloat = 44

    /// Search bar icon size — 15pt
    static let searchIconSize: CGFloat = 15

    /// Filter tab height — 32pt
    static let filterTabHeight: CGFloat = 32

    /// Filter tab horizontal padding — 16pt
    static let filterTabHPadding: CGFloat = 16

    /// FAB size — 64pt
    static let fabSize: CGFloat = 64

    /// FAB icon size — 20pt
    static let fabIconSize: CGFloat = 20

    /// Tab bar height — 73pt
    static let tabBarHeight: CGFloat = 73

    /// Chat row horizontal padding — 20pt
    static let chatRowHPadding: CGFloat = 20

    /// Chat row vertical padding — 12pt
    static let chatRowVPadding: CGFloat = 12

    /// Chat row min height — 80pt
    static let chatRowHeight: CGFloat = 80

    /// Unread badge min width — 20pt
    static let unreadBadgeSize: CGFloat = 20

    /// E2EE shield icon size — 12pt
    static let e2eeIconSize: CGFloat = 12

    /// Avatar-to-content gap — 12pt
    static let avatarContentGap: CGFloat = sm

    /// Name-to-preview vertical gap — 4pt
    static let namePreviewGap: CGFloat = xxs

    /// Filter tab horizontal gap — 8pt
    static let filterTabGap: CGFloat = xs

    /// Section header top padding — 8pt
    static let sectionHeaderTop: CGFloat = 8

    // MARK: - Chat Screen (Export Exact)

    /// Header avatar size — 40pt
    static let chatHeaderAvatarSize: CGFloat = 40
    /// Header avatar status dot — 12pt
    static let chatHeaderStatusDot: CGFloat = 12
    /// Header action button size — 36pt
    static let chatHeaderActionSize: CGFloat = 36
    /// Message bubble horizontal padding — 16pt
    static let bubbleHPadding: CGFloat = 16
    /// Message bubble vertical padding — 10pt
    static let bubbleVPadding: CGFloat = 10
    /// Message bubble tail radius — 4pt
    static let bubbleTailRadius: CGFloat = 4
    /// Message bubble main radius — 20pt
    static let bubbleMainRadius: CGFloat = 20
    /// Message max width fraction — 0.75
    static let messageMaxWidthFraction: CGFloat = 0.75
    /// Message gap — 12pt
    static let messageGap: CGFloat = 12
    /// Composer plus button size — 40pt
    static let composerButtonSize: CGFloat = 40
    /// Composer send button size — 44pt
    static let composerSendSize: CGFloat = 44
    /// Composer input border radius — 24pt
    static let composerInputRadius: CGFloat = 24
}
