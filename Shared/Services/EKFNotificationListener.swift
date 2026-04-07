import Foundation

/// Listens for EKF rotation_needed events from the server and delegates
/// to EKFClientService for handling.
/// Also runs periodic client-side purge of expired AccessK entries.
actor EKFNotificationListener {
    private let ekfClientService: EKFClientServiceProtocol
    private var isListening = false

    init(ekfClientService: EKFClientServiceProtocol) {
        self.ekfClientService = ekfClientService
    }

    /// Called when a rotation_needed event is received from the server
    /// (typically via a server-push field in the messaging stream response).
    func handleRotationEvent(keyClass: String) async {
        SanchrLogger.crypto.info("EKF rotation event received: class=\(keyClass)")
        await ekfClientService.handleRotationNeeded(keyClass: keyClass)
    }

    /// Periodically purge expired AccessK entries (client-side enforcement).
    /// Call this on app foreground or on a timer.
    func purgeExpiredKeys() async {
        SanchrLogger.crypto.info("Running client-side AccessK purge...")
        await ekfClientService.purgeExpiredAccessKeys()
    }

    /// Start periodic purge on a background timer (every 6 hours).
    func startPeriodicPurge() {
        guard !isListening else { return }
        isListening = true

        Task {
            while isListening {
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000) // 6 hours
                await purgeExpiredKeys()
            }
        }
        SanchrLogger.crypto.info("EKF periodic purge started (6h interval)")
    }

    func stop() {
        isListening = false
    }
}
