import Foundation

/// Decides whether received media may be fetched automatically on the current
/// network, or must wait for the user to tap the bubble.
///
/// The Chats settings screen has offered per-network auto-download pickers
/// since launch and synced them to the server, but nothing ever read them:
/// media downloaded on any connection regardless of the choice. Setting
/// "mobile data: no media" did not stop a single byte, which is a promise
/// about someone's data bill that the app was not keeping.
public enum AutoDownloadPolicy {

    /// How a given attachment is treated by the "Photos only" tier. Voice
    /// notes ride along with photos because they are seconds of AAC — tens of
    /// kilobytes — whereas video and documents are the payloads that make a
    /// metered connection expensive.
    public enum MediaClass: Equatable, Sendable {
        case photo
        case voiceNote
        case video
        case document
    }

    public enum Decision: Equatable, Sendable {
        /// Fetch now, without asking.
        case automatic
        /// Leave the bubble as a tappable placeholder; the user decides.
        case manual
    }

    /// The stored setting values, which are the raw strings persisted in
    /// `UserSettings` and shown in the pickers.
    public enum Tier: String, Sendable {
        case all
        case photos
        case none

        /// Unknown strings (an older or newer client writing a value we do not
        /// know) fall back to the most permissive tier rather than silently
        /// blocking every download.
        public init(setting: String) {
            self = Tier(rawValue: setting) ?? .all
        }
    }

    public static func mediaClass(forMimeType mimeType: String) -> MediaClass {
        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") { return .photo }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .voiceNote }
        return .document
    }

    /// Resolves the tier that applies on `connection`.
    ///
    /// Note the deliberate absence of a roaming case: iOS exposes no supported
    /// way to detect roaming — `CTCarrier` was deprecated in iOS 16 and now
    /// reports placeholder values — so cellular is cellular whether the device
    /// is at home or abroad. The roaming picker cannot be honoured and is
    /// handled at the UI layer rather than quietly mapped onto this one.
    public static func tier(
        for connection: NetworkMonitor.ConnectionType,
        wifi: String,
        mobile: String
    ) -> Tier? {
        switch connection {
        case .wifi, .wiredEthernet:
            return Tier(setting: wifi)
        case .cellular:
            return Tier(setting: mobile)
        case .none:
            // Offline: there is nothing to authorise. The download would fail
            // anyway, and reporting `manual` here would leave a stale
            // "Tap to download" badge on a bubble the moment Wi-Fi returned.
            return nil
        }
    }

    /// Whether `mimeType` may be fetched automatically right now.
    public static func decision(
        mimeType: String,
        connection: NetworkMonitor.ConnectionType,
        wifi: String,
        mobile: String
    ) -> Decision {
        guard let tier = tier(for: connection, wifi: wifi, mobile: mobile) else {
            return .automatic
        }
        switch tier {
        case .all:
            return .automatic
        case .photos:
            switch mediaClass(forMimeType: mimeType) {
            case .photo, .voiceNote: return .automatic
            case .video, .document: return .manual
            }
        case .none:
            return .manual
        }
    }
}

/// Device-local mirror of the auto-download settings.
///
/// The authoritative copy lives in the server-synced `UserSettings` loaded by
/// `SettingsViewModel`, but message bubbles render long before — and often
/// without — that screen ever being opened. Mirroring the two enforceable
/// values into `UserDefaults` on every load and save keeps the policy readable
/// synchronously from view code without threading the settings object through
/// the whole chat hierarchy.
public enum AutoDownloadSettingsStore {
    public static let wifiKey = "sanchr.autoDownload.wifi"
    public static let mobileKey = "sanchr.autoDownload.mobile"

    /// Defaults match `SettingsViewModel`'s, so a user who has never opened
    /// the settings screen gets the same behaviour the screen would show them.
    public static let wifiDefault = "all"
    public static let mobileDefault = "photos"

    public static func store(wifi: String, mobile: String) {
        let defaults = UserDefaults.standard
        defaults.set(wifi, forKey: wifiKey)
        defaults.set(mobile, forKey: mobileKey)
    }

    public static var wifi: String {
        UserDefaults.standard.string(forKey: wifiKey) ?? wifiDefault
    }

    public static var mobile: String {
        UserDefaults.standard.string(forKey: mobileKey) ?? mobileDefault
    }
}
