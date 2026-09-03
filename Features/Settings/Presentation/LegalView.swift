import SafariServices
import SanchrShared
import SwiftUI

/// The two documents App Review and users must be able to reach. They live
/// on sanchr.com so one edit updates every client; the app opens them in an
/// in-app Safari view rather than bouncing the user out to the browser.
enum LegalDocument: String, CaseIterable, Identifiable {
    case privacy
    case terms

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .privacy: URL(string: "https://sanchr.com/privacy")!
        case .terms: URL(string: "https://sanchr.com/terms")!
        }
    }

    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .terms: "Terms of Service"
        }
    }

    var subtitle: String {
        switch self {
        case .privacy: "What we can and cannot see, and why"
        case .terms: "The agreement for using Sanchr"
        }
    }

    var icon: String {
        switch self {
        case .privacy: "hand.raised"
        case .terms: "doc.text"
        }
    }

    /// The document a tapped link points at, so the login screen's markdown
    /// links open in the same in-app view.
    init?(url: URL) {
        guard let match = Self.allCases.first(where: { $0.url == url }) else { return nil }
        self = match
    }
}

/// In-app Safari for pages the user should read without leaving the app.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(SanchrColors.primary)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// Settings → Terms & Privacy. Used to lead to the privacy *toggles* screen,
/// so a reviewer following the row found no policy at all.
struct LegalView: View {
    @State private var presented: LegalDocument?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                heroCard
                documentsCard
                versionFooter
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Terms & Privacy")
        .sheet(item: $presented) { document in
            SafariSheet(url: document.url)
                .ignoresSafeArea()
        }
    }

    private var heroCard: some View {
        VStack(spacing: 14) {
            SettingsIconTile(systemName: "checkmark.shield", role: .accent, size: 64, iconSize: 24)

            VStack(spacing: 6) {
                Text("Built so we can't read your messages")
                    .font(SanchrTypography.sectionHeader)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("These documents say exactly what Sanchr keeps, what it never sees, and the rules for using it.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .settingsCard()
    }

    private var documentsCard: some View {
        VStack(spacing: 0) {
            ForEach(LegalDocument.allCases) { document in
                Button {
                    presented = document
                } label: {
                    SettingsInfoRow(icon: document.icon, title: document.title, subtitle: document.subtitle)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(document.title)
                .accessibilityHint("Opens in an in-app browser")

                if document != LegalDocument.allCases.last {
                    Divider().padding(.leading, 70)
                }
            }
        }
        .settingsCard()
    }

    private var versionFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Text("Sanchr \(version) (\(build)) · Zynclave Tech Private Limited")
            .font(SanchrTypography.captionSmall)
            .foregroundColor(SanchrExportColors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}
