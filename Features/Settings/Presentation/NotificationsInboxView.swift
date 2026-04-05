import SwiftUI

struct NotificationsInboxView: View {
    @Environment(\.dismiss) private var dismiss
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
            VStack(spacing: 0) {
                header

                VStack(spacing: 24) {
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
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $showPreferences) {
            NotificationsView()
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                SanchrIconButton(
                    systemName: "chevron.left",
                    foreground: .white,
                    background: Color.white.opacity(0.12)
                ) { dismiss() }

                Spacer()

                Text("Notifications")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.white)

                Spacer()

                Menu {
                    Button {
                        showPreferences = true
                    } label: {
                        Label("Notification Preferences", systemImage: "bell.badge")
                    }
                } label: {
                    Image(systemName: "ellipsis.vertical")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.top, 12)

            HStack(spacing: 8) {
                ForEach(InboxFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(selectedFilter == filter ? SanchrTypography.filterTabActive : SanchrTypography.filterTab)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(
                                (selectedFilter == filter ? Color.white.opacity(0.22) : Color.white.opacity(0.1))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.top, 18)
            .padding(.bottom, 18)
        }
        .background(
            LinearGradient(
                colors: [SanchrColors.primary, SanchrColors.primaryDark],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
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
                        .foregroundColor(item.tint)
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
                        .background(Color.white.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let actionTitle = item.actionTitle {
                    Button(actionTitle) {}
                        .font(SanchrTypography.caption)
                        .foregroundColor(item.tint)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(item.tint.opacity(0.12))
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
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(item.iconBackground)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }

            Circle()
                .fill(item.tint)
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: item.badgeIcon)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .offset(x: 1, y: 1)
        }
    }

    private var background: LinearGradient {
        switch item.category {
        case .message:
            return LinearGradient(
                colors: [SanchrColors.primary.opacity(0.06), SanchrColors.accent.opacity(0.06)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .security:
            return LinearGradient(
                colors: [Color(hex: 0xECFDF5), Color(hex: 0xF0FDF4)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .system:
            return LinearGradient(
                colors: [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderColor: Color {
        switch item.category {
        case .message:
            return SanchrColors.primary.opacity(0.18)
        case .security:
            return Color(hex: 0xBBF7D0)
        case .system:
            return Color(hex: 0xE5E7EB)
        }
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
    let badgeIcon: String
    let iconBackground: Color
    let tint: Color
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
            icon: "person.fill",
            badgeIcon: "message.fill",
            iconBackground: SanchrColors.primary,
            tint: SanchrColors.primary,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Today",
            category: .security,
            title: "Security Verified",
            message: "Mike Johnson verified your security code",
            detail: "28394 75621 94857",
            timeAgo: "15m",
            icon: "shield.fill",
            badgeIcon: "checkmark",
            iconBackground: Color(hex: 0x10B981),
            tint: Color(hex: 0x16A34A),
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Today",
            category: .system,
            title: "New Group",
            message: "Emma Davis added you to \"Design Team\"",
            detail: nil,
            timeAgo: "1h",
            icon: "person.3.fill",
            badgeIcon: "plus",
            iconBackground: Color(hex: 0x8B5CF6),
            tint: SanchrColors.accent,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Yesterday",
            category: .system,
            title: "Alex Turner",
            message: "Shared 3 photos in Vault",
            detail: "Self-destructing media expires in 24 hours",
            timeAgo: "18h",
            icon: "lock.doc.fill",
            badgeIcon: "photo.fill",
            iconBackground: Color(hex: 0xA855F7),
            tint: Color(hex: 0xA855F7),
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Yesterday",
            category: .system,
            title: "Sanchr",
            message: "Your encryption keys have been automatically refreshed for enhanced security.",
            detail: nil,
            timeAgo: "22h",
            icon: "bell.fill",
            badgeIcon: "shield.fill",
            iconBackground: SanchrColors.accent,
            tint: SanchrExportColors.textTertiary,
            actionTitle: nil
        ),
        NotificationFeedItem(
            section: "Yesterday",
            category: .system,
            title: "Jessica Lee",
            message: "Missed voice call",
            detail: nil,
            timeAgo: "23h",
            icon: "phone.down.fill",
            badgeIcon: "phone.fill",
            iconBackground: SanchrColors.error,
            tint: SanchrColors.error,
            actionTitle: "Call Back"
        ),
    ]
}
