import SwiftUI

/// Main entry point for the Sanchr encrypted messaging application.
/// Configures the app environment, dependency injection, and root scene.
@main
struct SanchrApp: App {
    @State private var container = DependencyContainer()
    @State private var appRouter = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .environment(appRouter)
                .onAppear {
                    configureFonts()
                    configureAppearance()
                }
        }
    }

    // MARK: - Setup

    /// Registers custom fonts bundled with the application.
    private func configureFonts() {
        // TODO: Register Afacad and Inter font families from Resources/Fonts
        // CTFontManagerRegisterFontsForURL(fontURL, .process, nil)
    }

    /// Applies global appearance overrides for UIKit components embedded in SwiftUI.
    private func configureAppearance() {
        // TODO: Configure UINavigationBar, UITabBar default appearances
        // to match SanchrTheme tokens.
    }
}

// MARK: - Root View

/// Presents either the authentication flow or the main tab interface
/// based on the current session state.
struct RootView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if container.sessionService.isAuthenticated {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: container.sessionService.isAuthenticated)
    }
}
