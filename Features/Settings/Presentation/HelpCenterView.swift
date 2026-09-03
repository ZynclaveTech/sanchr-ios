import SwiftUI
import SanchrShared

/// Help center: searchable articles about what the app does, grouped by
/// category, plus the two support channels that exist.
struct HelpCenterView: View {
    @State private var searchText = ""
    @State private var expandedFAQ: String?
    @State private var showContactForm = false

    private var searchResults: [HelpArticle] { HelpContent.search(searchText) }
    private var isSearching: Bool { searchText.trimmingCharacters(in: .whitespaces).count > 1 }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                searchSection
                if isSearching {
                    searchResultsSection
                } else {
                    quickActions
                    popularTopicsSection
                    categoriesSection
                    faqSection
                    supportCTA
                }
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 28)
        }
        .sanchrSettingsSubscreenNavigation(title: "Help Center")
        .sheet(isPresented: $showContactForm) {
            ContactSupportForm()
        }
    }

    private var searchSection: some View {
        SanchrSearchField(placeholder: "Search for help...", text: $searchText) {
            EmptyView()
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(searchResults.isEmpty ? "No matches" : "\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
            if searchResults.isEmpty {
                VStack(spacing: 10) {
                    Text("Nothing in the Help Center matches that.")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                    Button("Ask support instead") { showContactForm = true }
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.sanchrPrimary)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .settingsCard()
            }
            ForEach(searchResults) { article in
                NavigationLink {
                    HelpArticleView(article: article)
                } label: {
                    HelpArticleRow(article: article)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Two things that exist: an email to support with device details, and
    // a direct line for security reports. The old first card promised a
    // chat channel Sanchr does not run.
    private var quickActions: some View {
        HStack(spacing: 12) {
            Button {
                showContactForm = true
            } label: {
                quickActionCard(
                    title: "Email Support",
                    subtitle: "We reply by email",
                    icon: "envelope"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if let url = URL(string: "mailto:security@sanchr.com?subject=Security%20report") {
                    UIApplication.shared.open(url)
                }
            } label: {
                quickActionCard(
                    title: "Report a Security Issue",
                    subtitle: "security@sanchr.com",
                    icon: "exclamationmark.shield"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var popularTopicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Popular Topics")

            VStack(spacing: 12) {
                ForEach(HelpContent.popularIDs.compactMap(HelpContent.article)) { article in
                    NavigationLink {
                        HelpArticleView(article: article)
                    } label: {
                        HelpArticleRow(article: article)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Browse by Category")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(HelpCategory.allCases) { category in
                    NavigationLink {
                        HelpCategoryView(category: category)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            SettingsIconTile(systemName: category.icon, size: 48, iconSize: 18)

                            Text(category.title)
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(SanchrExportColors.textPrimary)
                                .multilineTextAlignment(.leading)
                            Text("\(category.articles.count) article\(category.articles.count == 1 ? "" : "s")")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .settingsCard()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Frequently Asked")

            VStack(spacing: 12) {
                ForEach(HelpContent.faqs, id: \.question) { faq in
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedFAQ = expandedFAQ == faq.question ? nil : faq.question
                            }
                        } label: {
                            HStack {
                                Text(faq.question)
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                                    .rotationEffect(.degrees(expandedFAQ == faq.question ? 180 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(expandedFAQ == faq.question ? .isSelected : [])

                        if expandedFAQ == faq.question {
                            Text(faq.answer)
                                .font(SanchrTypography.caption)
                                .foregroundColor(SanchrExportColors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                    }
                    .settingsCard()
                }
            }
        }
    }

    private var supportCTA: some View {
        VStack(spacing: 12) {
            SettingsIconTile(systemName: "headphones", role: .accent, size: 64, iconSize: 26)

            Text("Still Need Help?")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text("Tell us what is happening and we will reply by email, usually within a day.")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)

            Button("Contact Support") {
                showContactForm = true
            }
            .font(SanchrTypography.bodyBold)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .frame(height: 46)
            .background(Color.sanchrPrimary)
            .clipShape(Capsule())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .settingsCard(cornerRadius: 26)
    }

    private func quickActionCard(
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsIconTile(systemName: icon, role: .accent, size: 48, iconSize: 18)

            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)
                .multilineTextAlignment(.leading)

            Text(subtitle)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .settingsCard()
    }

    private func sectionTitle(_ title: String) -> some View {
        SettingsSectionTitle(title: title)
    }
}

struct ContactSupportForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var message = ""
    @State private var includeDeviceInfo = true

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    field(title: "Subject", text: $subject, placeholder: "How can we help?")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Message")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)

                        TextEditor(text: $message)
                            .font(SanchrTypography.body)
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .frame(minHeight: 180)
                            .padding(12)
                            .scrollContentBackground(.hidden)
                            .settingsCard(cornerRadius: 18)
                    }

                    Toggle(isOn: $includeDeviceInfo) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Include device info")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(SanchrExportColors.textPrimary)
                            Text("Attach device model, iOS version, and app version for faster troubleshooting.")
                                .font(SanchrTypography.caption)
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                    }
                    .tint(.sanchrPrimary)
                    .padding(18)
                    .settingsCard(cornerRadius: 18)
                }
                .padding(SanchrExportMetrics.sectionHorizontal)
                .padding(.top, 16)
            }
            .sanchrSettingsSubscreenNavigation(title: "Contact Support")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendSupportEmail()
                        dismiss()
                    }
                    .disabled(subject.isEmpty || message.isEmpty)
                }
            }
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)

            TextField(placeholder, text: text)
                .font(SanchrTypography.body)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .settingsCard(cornerRadius: 18)
        }
    }

    private func sendSupportEmail() {
        var body = message
        if includeDeviceInfo {
            let device = UIDevice.current
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            body += "\n\n---\nDevice: \(device.model)\niOS: \(device.systemVersion)\nApp: \(appVersion)"
        }

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(string: "mailto:support@sanchr.com?subject=\(encodedSubject)&body=\(encodedBody)") {
            UIApplication.shared.open(url)
        }
    }
}
