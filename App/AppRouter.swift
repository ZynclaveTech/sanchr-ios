import SwiftUI

/// Centralized navigation coordinator managing the root tab selection
/// and per-tab navigation stacks.
@Observable
final class AppRouter {
    /// Active tab in the main interface.
    enum Tab: Int, CaseIterable, Identifiable {
        case chats = 0
        case calls
        case contacts
        case settings

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .chats: "Chats"
            case .calls: "Calls"
            case .contacts: "Contacts"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .chats: "message.fill"
            case .calls: "phone.fill"
            case .contacts: "person.2.fill"
            case .settings: "gearshape.fill"
            }
        }
    }

    var selectedTab: Tab = .chats

    /// Per-tab navigation paths for independent stack management.
    var chatsPath = NavigationPath()
    var callsPath = NavigationPath()
    var contactsPath = NavigationPath()
    var settingsPath = NavigationPath()
    var pendingConversationId: String?
    var pendingCallId: String?

    /// Total unread message count across all conversations (drives tab badge).
    var chatUnreadCount: Int = 0

    /// Resets all navigation stacks to their root views.
    func resetAllNavigation() {
        chatsPath = NavigationPath()
        callsPath = NavigationPath()
        contactsPath = NavigationPath()
        settingsPath = NavigationPath()
    }

    /// Switches to a tab, resetting its stack if already selected (tap-to-pop).
    func selectTab(_ tab: Tab) {
        if selectedTab == tab {
            switch tab {
            case .chats: chatsPath = NavigationPath()
            case .calls: callsPath = NavigationPath()
            case .contacts: contactsPath = NavigationPath()
            case .settings: settingsPath = NavigationPath()
            }
        } else {
            selectedTab = tab
        }
    }

    func routeNotificationAction(_ action: NotificationAction) {
        switch action {
        case .openConversation(let conversationId):
            selectedTab = .chats
            pendingConversationId = conversationId
        case .openCall(let callId):
            selectedTab = .calls
            pendingCallId = callId
        case .replyToMessage(let conversationId, _):
            selectedTab = .chats
            pendingConversationId = conversationId
        case .none:
            break
        }
    }

    func clearPendingConversation() {
        pendingConversationId = nil
    }

    func clearPendingCall() {
        pendingCallId = nil
    }
}

// MARK: - Main Tab View

/// Root tabbed interface with four primary sections.
/// Configures native tab bar appearance with Figma design tokens.
struct MainTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.chatsPath) {
                ChatsListView()
            }
            .tabItem {
                Label(AppRouter.Tab.chats.title, systemImage: AppRouter.Tab.chats.systemImage)
            }
            .tag(AppRouter.Tab.chats)
            .badge(router.chatUnreadCount > 0 ? router.chatUnreadCount : 0)

            NavigationStack(path: $router.callsPath) {
                CallsListView()
            }
            .tabItem {
                Label(AppRouter.Tab.calls.title, systemImage: AppRouter.Tab.calls.systemImage)
            }
            .tag(AppRouter.Tab.calls)

            NavigationStack(path: $router.contactsPath) {
                ContactsView()
            }
            .tabItem {
                Label(
                    AppRouter.Tab.contacts.title, systemImage: AppRouter.Tab.contacts.systemImage)
            }
            .tag(AppRouter.Tab.contacts)

            NavigationStack(path: $router.settingsPath) {
                SettingsView()
            }
            .tabItem {
                Label(
                    AppRouter.Tab.settings.title, systemImage: AppRouter.Tab.settings.systemImage)
            }
            .tag(AppRouter.Tab.settings)
        }
        .tint(Color.sanchrPrimary)
        .onAppear { configureTabBarAppearance() }
        .onChange(of: colorScheme) { _, _ in configureTabBarAppearance() }
        .fullScreenCover(
            isPresented: Binding(
                get: { container.callManager.callState != .idle },
                set: { presented in
                    if !presented {
                        container.callManager.resetState()
                    }
                }
            )
        ) {
            ActiveCallView()
        }
    }

    /// Configures the UITabBar appearance to match Figma design tokens.
    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()

        // Background
        let bgColor =
            colorScheme == .dark
            ? UIColor(SanchrColors.backgroundDark)
            : UIColor(SanchrColors.backgroundLight)
        appearance.backgroundColor = bgColor

        // Top separator — subtle border
        let borderColor =
            colorScheme == .dark
            ? UIColor(SanchrColors.borderDark)
            : UIColor(SanchrColors.borderLight)
        appearance.shadowColor = borderColor

        // Active tab item (primary indigo)
        let activeColor = UIColor(SanchrColors.primary)
        appearance.stackedLayoutAppearance.selected.iconColor = activeColor
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: activeColor,
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
        ]

        // Inactive tab item
        let inactiveColor =
            colorScheme == .dark
            ? UIColor(SanchrColors.textTertiaryDark)
            : UIColor(SanchrColors.textTertiaryLight)
        appearance.stackedLayoutAppearance.normal.iconColor = inactiveColor
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: inactiveColor,
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
        ]

        // Badge (indigo background, white text)
        appearance.stackedLayoutAppearance.selected.badgeBackgroundColor = UIColor(
            SanchrColors.primary)
        appearance.stackedLayoutAppearance.normal.badgeBackgroundColor = UIColor(
            SanchrColors.primary)
        appearance.stackedLayoutAppearance.selected.badgeTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 11, weight: .bold),
        ]
        appearance.stackedLayoutAppearance.normal.badgeTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 11, weight: .bold),
        ]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
