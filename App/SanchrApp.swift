import SwiftUI
import UserNotifications

/// Main entry point for the Sanchr encrypted messaging application.
/// Configures the app environment, dependency injection, APNs delegate, and root scene.
@main
struct SanchrApp: App {
    @UIApplicationDelegateAdaptor(SanchrAppDelegate.self) private var appDelegate
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
                    configurePushManager()
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

    /// Wire the PushManager as the UNUserNotificationCenter delegate
    /// and share it with the AppDelegate for token forwarding.
    private func configurePushManager() {
        let pushManager = container.pushManager
        UNUserNotificationCenter.current().delegate = pushManager
        appDelegate.pushManager = pushManager

        SanchrLogger.push.info("PushManager wired as UNUserNotificationCenter delegate")
    }
}

// MARK: - AppDelegate

/// UIKit app delegate required for APNs token callbacks and silent push handling.
/// SwiftUI's `@UIApplicationDelegateAdaptor` bridges these callbacks into the SwiftUI lifecycle.
final class SanchrAppDelegate: NSObject, UIApplicationDelegate {

    /// Injected by SanchrApp after the container is initialized.
    var pushManager: PushManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SanchrLogger.app.info("Application didFinishLaunching")

        // Check if launched from a notification
        if let remoteNotification = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task {
                await pushManager?.handleNotification(userInfo: remoteNotification)
            }
        }

        return true
    }

    /// Called when APNs successfully registers and delivers the device token.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushManager?.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    /// Called when APNs registration fails.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        SanchrLogger.push.error("APNs registration failed: \(error.localizedDescription)")
    }

    /// Handle silent/background push notifications (content-available: 1).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let pushManager else {
            completionHandler(.noData)
            return
        }

        Task {
            let result = await pushManager.handleSilentPush(userInfo: userInfo)
            completionHandler(result)
        }
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
                    .task {
                        await requestPushPermissionIfNeeded()
                    }
            } else {
                LoginView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: container.sessionService.isAuthenticated)
    }

    /// Request push notification permission on first launch after authentication.
    /// This ensures the user sees the permission dialog only after they are logged in.
    private func requestPushPermissionIfNeeded() async {
        let pushManager = container.pushManager
        if !pushManager.isPermissionGranted {
            await pushManager.requestAuthorization()
        }
    }
}
