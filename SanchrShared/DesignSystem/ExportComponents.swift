import SwiftUI

public enum SanchrExportMetrics {
    public static let screenHorizontal: CGFloat = 20
    public static let sectionHorizontal: CGFloat = 16
    public static let topBarTop: CGFloat = 14
    public static let rootTop: CGFloat = 16
    public static let chipHeight: CGFloat = 38
    public static let cardRadius: CGFloat = 20
    public static let softRadius: CGFloat = 16
    public static let largeRadius: CGFloat = 24
    public static let iconButtonSize: CGFloat = 40
    public static let contentSpacing: CGFloat = 20
}

public enum SanchrExportColors {
    public static let background = Color(uiColor: .systemBackground)
    public static let surface = Color(uiColor: .secondarySystemBackground)
    public static let surfaceSoft = Color(uiColor: .systemGroupedBackground)
    public static let surfaceMuted = Color(uiColor: .tertiarySystemFill)
    public static let textPrimary = Color(uiColor: .label)
    public static let textSecondary = Color(uiColor: .secondaryLabel)
    public static let textTertiary = Color(uiColor: .tertiaryLabel)
    public static let line = Color(uiColor: .separator)
    public static let selectedChip = SanchrColors.primary
}

extension View {
    public func sanchrExportBackground() -> some View {
        background(SanchrExportColors.background.ignoresSafeArea())
    }
}

public struct SanchrPrimaryCTA: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
    }
}

public struct SanchrBrandHeader<Trailing: View>: View {
    public let title: String
    @ViewBuilder public var trailing: Trailing

    public init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image("SanchrLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(SquircleShape())

                Text(title)
                    .font(SanchrTypography.chatListTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)
            }

            Spacer()

            trailing
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.top, SanchrExportMetrics.rootTop)
        .padding(.bottom, 12)
        .background(SanchrExportColors.background.ignoresSafeArea(edges: .top))
    }
}

public struct SanchrCenteredHeader<Leading: View, Trailing: View>: View {
    public let title: String
    @ViewBuilder public var leading: Leading
    @ViewBuilder public var trailing: Trailing

    public init(
        title: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 40, height: 40)

            Spacer()

            Text(title)
                .font(SanchrTypography.cardTitle)
                .foregroundColor(SanchrExportColors.textPrimary)

            Spacer()

            trailing
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
        .padding(.top, SanchrExportMetrics.topBarTop)
        .padding(.bottom, 12)
        .background(SanchrExportColors.background.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SanchrExportColors.line)
                .frame(height: 1)
        }
    }
}

public struct SanchrIconButton: View {
    public let systemName: String
    public let foreground: Color
    public let background: Color
    public let action: () -> Void

    public init(
        systemName: String,
        foreground: Color = SanchrExportColors.textSecondary,
        background: Color = .clear,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.foreground = foreground
        self.background = background
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: SanchrExportMetrics.iconButtonSize, height: SanchrExportMetrics.iconButtonSize)
                .background(background)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

public struct SanchrSearchField<Trailing: View>: View {
    public let placeholder: String
    @Binding public var text: String
    @ViewBuilder public var trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    public init(
        placeholder: String,
        text: Binding<String>,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.placeholder = placeholder
        self._text = text
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: SanchrSpacing.searchIconSize, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)

            TextField(placeholder, text: $text)
                .font(SanchrTypography.searchPlaceholder)
                .foregroundColor(SanchrExportColors.textPrimary)
                .focused($isFocused)

            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: SanchrSpacing.searchBarHeight)
        .background(Color.sanchrSearchBackground(colorScheme))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(isFocused ? SanchrColors.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        }
    }
}

public struct SanchrFilterChip: View {
    public let title: String
    public let isSelected: Bool
    public let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(isSelected ? SanchrTypography.filterTabActive : SanchrTypography.filterTab)
                .foregroundColor(isSelected ? .white : SanchrExportColors.textSecondary)
                .padding(.horizontal, SanchrSpacing.filterTabHPadding)
                .frame(height: SanchrSpacing.filterTabHeight)
                .background(isSelected ? SanchrExportColors.selectedChip : Color.sanchrChipInactive(colorScheme))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

public struct SanchrModeChip: View {
    public let isActive: Bool
    public let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(isActive: Bool, action: @escaping () -> Void) {
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Sanchr Mode")
                    .font(SanchrTypography.filterTab)
            }
            .foregroundColor(isActive ? SanchrColors.primary : SanchrExportColors.textSecondary)
            .padding(.horizontal, SanchrSpacing.filterTabHPadding)
            .frame(height: SanchrSpacing.filterTabHeight)
            .background(Color.sanchrChipInactive(colorScheme))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

public struct SanchrSectionEyebrow: View {
    public let title: String
    public var systemImage: String?

    public init(title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
            Text(title)
                .font(SanchrTypography.sectionLabel)
                .tracking(1.2)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.top, SanchrSpacing.sectionHeaderTop)
        .padding(.bottom, 4)
    }
}

public struct SquircleShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.28, y: 0))
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.30),
            control1: CGPoint(x: w * 0.72, y: 0),
            control2: CGPoint(x: w, y: h * 0.0)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.70, y: h),
            control1: CGPoint(x: w, y: h * 0.70),
            control2: CGPoint(x: w, y: h)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: h * 0.70),
            control1: CGPoint(x: w * 0.30, y: h),
            control2: CGPoint(x: 0, y: h)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.28, y: 0),
            control1: CGPoint(x: 0, y: h * 0.30),
            control2: CGPoint(x: 0, y: 0)
        )
        return path
    }
}

public struct SanchrGradientButtonLabel: View {
    public let title: String
    public let systemName: String?

    public init(title: String, systemName: String? = nil) {
        self.title = title
        self.systemName = systemName
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .bold))
            }
            Text(title)
                .font(SanchrTypography.bodyBold)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary, SanchrColors.primaryDark],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(Capsule())
        .shadow(color: SanchrColors.primary.opacity(0.25), radius: 20, x: 0, y: 10)
    }
}
