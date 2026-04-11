import SwiftUI
import SanchrShared

enum SettingsIconRole {
    case neutral
    case accent
    case success
    case warning
    case destructive

    var color: Color {
        switch self {
        case .neutral:
            return SanchrExportColors.textSecondary
        case .accent:
            return .sanchrPrimary
        case .success:
            return .sanchrSuccess
        case .warning:
            return .sanchrWarning
        case .destructive:
            return .sanchrError
        }
    }
}

struct SettingsIconTile: View {
    let systemName: String
    var role: SettingsIconRole = .neutral
    var size: CGFloat = 42
    var iconSize: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(SanchrExportColors.surfaceMuted)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(role.color)
            }
    }
}

struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(SanchrExportColors.textTertiary)
    }
}

struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(SanchrTypography.sectionLabel)
            .tracking(1.2)
            .foregroundColor(SanchrExportColors.textSecondary)
    }
}

struct SettingsInfoRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    var role: SettingsIconRole = .neutral
    @ViewBuilder let trailing: Trailing

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        role: SettingsIconRole = .neutral,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemName: icon, role: role)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
            trailing
        }
    }
}

extension SettingsInfoRow where Trailing == SettingsChevron {
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        role: SettingsIconRole = .neutral
    ) {
        self.init(icon: icon, title: title, subtitle: subtitle, role: role) {
            SettingsChevron()
        }
    }
}

extension View {
    func settingsCard(cornerRadius: CGFloat = 22) -> some View {
        background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
            }
    }
}
