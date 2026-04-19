import Foundation

/// Type-safe localization service for managing translated strings across the app.
final class LocalizationService: Sendable {
    enum Key: String {
        // Settings
        case settingsSecurity = "settings.security"
        case settingsBiometricTitle = "settings.biometric.title"
        case settingsDeleteAccount = "settings.deleteAccount"
        // Add more keys as needed
    }

    static let shared = LocalizationService()

    func localize(_ key: Key) -> String {
        NSLocalizedString(key.rawValue, comment: "")
    }

    var currentLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}
