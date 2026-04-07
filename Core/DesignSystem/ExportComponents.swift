import SwiftUI
import SanchrShared

enum SanchrExportMetrics {
    static let screenHorizontal: CGFloat = 20
    static let sectionHorizontal: CGFloat = 16
    static let topBarTop: CGFloat = 14
    static let rootTop: CGFloat = 16
    static let chipHeight: CGFloat = 38
    static let cardRadius: CGFloat = 20
    static let softRadius: CGFloat = 16
    static let largeRadius: CGFloat = 24
    static let iconButtonSize: CGFloat = 40
    static let contentSpacing: CGFloat = 20
}

enum SanchrExportColors {
    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceSoft = Color(uiColor: .systemGroupedBackground)
    static let surfaceMuted = Color(uiColor: .tertiarySystemFill)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let line = Color(uiColor: .separator)
    static let selectedChip = SanchrColors.primary
}

extension View {
    func sanchrExportBackground() -> some View {
        background(SanchrExportColors.background.ignoresSafeArea())
    }
}

struct SanchrPrimaryCTA: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
    }
}

struct SanchrBrandHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
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

struct SanchrCenteredHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
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

struct SanchrIconButton: View {
    let systemName: String
    let foreground: Color
    let background: Color
    let action: () -> Void

    init(
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

    var body: some View {
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

struct SanchrSearchField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    init(
        placeholder: String,
        text: Binding<String>,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.placeholder = placeholder
        self._text = text
        self.trailing = trailing()
    }

    var body: some View {
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

struct SanchrFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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

struct SanchrModeChip: View {
    let isActive: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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

struct SanchrSectionEyebrow: View {
    let title: String
    var systemImage: String?

    var body: some View {
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

struct SquircleShape: Shape {
    func path(in rect: CGRect) -> Path {
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

struct SanchrGradientButtonLabel: View {
    let title: String
    let systemName: String?

    var body: some View {
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
