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
}

// MARK: - Main Tab View

/// Root tabbed interface with four primary sections.
struct MainTabView: View {
    @Environment(AppRouter.self) private var router

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
                Label(AppRouter.Tab.contacts.title, systemImage: AppRouter.Tab.contacts.systemImage)
            }
            .tag(AppRouter.Tab.contacts)

            NavigationStack(path: $router.settingsPath) {
                SettingsView()
            }
            .tabItem {
                Label(AppRouter.Tab.settings.title, systemImage: AppRouter.Tab.settings.systemImage)
            }
            .tag(AppRouter.Tab.settings)
        }
        .tint(Color.sanchrPrimary)
    }
}
