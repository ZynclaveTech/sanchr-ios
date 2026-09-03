import SanchrShared
import SwiftUI

struct HelpArticleView: View {
    let article: HelpArticle

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    SettingsIconTile(systemName: article.icon, role: .accent, size: 56, iconSize: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.category.title.uppercased())
                            .font(SanchrTypography.sectionLabel)
                            .tracking(1.2)
                            .foregroundColor(SanchrExportColors.textSecondary)
                        Text(article.title)
                            .font(SanchrTypography.sectionHeader)
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(Array(article.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 10) {
                        if let heading = section.heading {
                            Text(heading)
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(SanchrExportColors.textPrimary)
                        }
                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .font(SanchrTypography.body)
                                .foregroundColor(SanchrExportColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(SanchrTypography.captionSmall)
                                    .fontWeight(.bold)
                                    .foregroundColor(SanchrColors.primary)
                                    .frame(width: 22, height: 22)
                                    .background(SanchrColors.primary.opacity(0.12))
                                    .clipShape(Circle())
                                Text(step)
                                    .font(SanchrTypography.body)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCard()
                }

                if let destination = article.destination {
                    NavigationLink {
                        destinationView(destination)
                    } label: {
                        HStack {
                            Text(destination.label)
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(SanchrColors.primary)
                            Spacer()
                            SettingsChevron()
                        }
                        .padding(18)
                        .settingsCard()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .sanchrSettingsSubscreenNavigation(title: "Help")
    }

    @ViewBuilder
    private func destinationView(_ destination: HelpDestination) -> some View {
        switch destination {
        case .security: SecurityView()
        case .privacy: PrivacyView()
        case .chatSettings: ChatSettingsView()
        case .backup: BackupView()
        case .notifications: NotificationsView()
        case .storage: StorageView()
        case .appearance: AppearanceView()
        case .contactUs: ContactUsView()
        case .registrationLock: RegistrationLockView()
        case .blockedContacts: BlockedContactsView()
        }
    }
}

/// One category's articles.
struct HelpCategoryView: View {
    let category: HelpCategory

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                ForEach(category.articles) { article in
                    NavigationLink {
                        HelpArticleView(article: article)
                    } label: {
                        HelpArticleRow(article: article)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .sanchrSettingsSubscreenNavigation(title: category.title)
    }
}

struct HelpArticleRow: View {
    let article: HelpArticle

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemName: article.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(article.summary)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            SettingsChevron()
        }
        .padding(16)
        .settingsCard()
    }
}
