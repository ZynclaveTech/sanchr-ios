import SwiftUI
import SanchrShared

struct NotificationsInboxView: View {
    @State private var selectedFilter: InboxFilter = .all
    @State private var items = NotificationFeedItem.seedData
    @State private var showPreferences = false

    enum InboxFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case messages = "Messages"
        case security = "Security"

        var id: String { rawValue }
    }

    private var filteredItems: [NotificationFeedItem] {
        switch selectedFilter {
        case .all:
            return items
        case .messages:
            return items.filter { $0.category == .message }
        case .security:
            return items.filter { $0.category == .security }
        }
    }

    private var todayItems: [NotificationFeedItem] {
        filteredItems.filter { $0.section == "Today" }
    }

    private var yesterdayItems: [NotificationFeedItem] {
        filteredItems.filter { $0.section == "Yesterday" }
    }

    private var weekItems: [NotificationFeedItem] {
        filteredItems.filter { $0.section == "This Week" }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                filterBar

                if !todayItems.isEmpty {
                    notificationSection(
                        title: "Today",
                        showsMarkAllRead: true,
                        items: todayItems
                    )
                }

                if !yesterdayItems.isEmpty {
                    notificationSection(title: "Yesterday", items: yesterdayItems)
                }

                if !weekItems.isEmpty {
                    notificationSection(title: "This Week", items: weekItems)
                }
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 32)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Notifications")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showPreferences = true
                    } label: {
                        Label("Notification Preferences", systemImage: "bell.badge")
                        .contentShape(Rectangle())
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                    .contentShape(Rectangle())
                }
            }
        }
        .navigationDestination(isPresented: $showPreferences) {
            NotificationsView()
        }
    }

    private var filterBar: some View {
            HStack(spacing: 8) {
                ForEach(InboxFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(selectedFilter == filter ? SanchrTypography.filterTabActive : SanchrTypography.filterTab)
                            .foregroundColor(selectedFilter == filter ? .white : SanchrExportColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(
                                selectedFilter == filter
                                    ? Color.sanchrPrimary
                                    : SanchrExportColors.surface
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    private func notificationSection(
        title: String,
        showsMarkAllRead: Bool = false,
        items: [NotificationFeedItem]
    ) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(SanchrTypography.sectionLabel)
                    .tracking(1.2)
                    .foregroundColor(SanchrExportColors.textSecondary)

                Spacer()

                if showsMarkAllRead {
                    Button("Mark all read") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.items = self.items.map { item in
                                var item = item
                                item.isUnread = false
                                return item
                            }
                        }
                    }
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(.sanchrPrimary)
                }
            }

            ForEach(items) { item in
                NotificationInboxCard(item: item)
            }
        }
    }
}

private struct NotificationInboxCard: View {
    let item: NotificationFeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)

                    Spacer()

                    Text(item.timeAgo)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textTertiary)
                }

                Text(item.message)
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = item.detail {
                    Text(detail)
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SanchrExportColors.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let actionTitle = item.actionTitle {
                    Button(actionTitle) {}
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(SanchrExportColors.surfaceMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(16)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var icon: some View {
        SettingsIconTile(systemName: item.icon, role: item.role, size: 52, iconSize: 18)
    }

    private var background: Color {
        SanchrExportColors.surface
    }

    private var borderColor: Color {
        SanchrExportColors.line.opacity(0.55)
    }
}

private struct NotificationFeedItem: Identifiable {
    enum Category {
        case message
        case security
        case system
    }

    let id = UUID()
    let section: String
    let category: Category
    let title: String
    let message: String
    let detail: String?
    let timeAgo: String
    let icon: String
    let role: SettingsIconRole
    let actionTitle: String?
    var isUnread: Bool = true

    static let seedData: [NotificationFeedItem] = [
        NotificationFeedItem(
            section: "Today",
            category: .message,
            title: "Sarah Mitchell",
            message: "Sent you a message",
            detail: "Hey! Did you get a chance to review the project files I sent earlier?",
            timeAgo: "2m",
            icon: "person",
            role: .neutral,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Today",
            category: .security,
            title: "Security Verified",
            message: "Mike Johnson verified your security code",
            detail: "28394 75621 94857",
            timeAgo: "15m",
            icon: "shield",
            role: .success,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Today",
            category: .system,
            title: "New Group",
            message: "Emma Davis added you to \"Design Team\"",
            detail: nil,
            timeAgo: "1h",
            icon: "person.3",
            role: .neutral,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Yesterday",
            category: .system,
            title: "Alex Turner",
            message: "Shared 3 photos in Vault",
            detail: "Self-destructing media expires in 24 hours",
            timeAgo: "18h",
            icon: "lock.doc",
            role: .neutral,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Yesterday",
            category: .system,
            title: "Sanchr",
            message: "Your encryption keys have been automatically refreshed for enhanced security.",
            detail: nil,
            timeAgo: "22h",
            icon: "bell",
            role: .neutral,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Yesterday",
            category: .system,
            title: "Jessica Lee",
            message: "Missed voice call",
            detail: nil,
            timeAgo: "23h",
            icon: "phone.down",
            role: .destructive,
            actionTitle: "Call Back"
        ),
    ]
}
