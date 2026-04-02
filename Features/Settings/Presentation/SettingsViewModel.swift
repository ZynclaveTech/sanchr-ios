import Foundation

/// View model for the settings screen.
@Observable
final class SettingsViewModel {
    var displayName: String = "Sanchr User"
    var phoneNumber: String = "+1 234 567 890"
    var errorMessage: String?

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    func loadProfile() async {
        // TODO: Load profile from session/repository
    }

    func logout(authService: AuthServiceProtocol) async {
        do {
            try await authService.logout()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
