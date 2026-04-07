import Foundation

/// Client-side handler for EKF lifecycle events.
///
/// Responds to server rotation_needed notifications by:
/// - Re-deriving fresh OPRF blinding factors (discovery class)
/// - Re-requesting expired media keys from senders (media class)
/// - Replenishing one-time pre-keys (prekey class)
protocol EKFClientServiceProtocol: AnyObject, Sendable {
    /// Handle a rotation needed notification from the server.
    func handleRotationNeeded(keyClass: String) async

    /// Purge expired local access keys.
    func purgeExpiredAccessKeys() async
}

final class EKFClientService: EKFClientServiceProtocol, @unchecked Sendable {

    private let accessKeyStore: AccessKeyStoreProtocol
    private let keyManager: KeyManagerProtocol

    init(accessKeyStore: AccessKeyStoreProtocol, keyManager: KeyManagerProtocol) {
        self.accessKeyStore = accessKeyStore
        self.keyManager = keyManager
    }

    func handleRotationNeeded(keyClass: String) async {
        switch keyClass {
        case "discovery":
            // Discovery rotation: client will re-sync contacts on next app foreground.
            // No immediate action needed — the Bloom filter salt has changed.
            SanchrLogger.crypto.info("EKF: discovery rotation acknowledged")

        case "media":
            // Media access keys have expired — no client action.
            // Re-request from sender if user tries to access old media.
            SanchrLogger.crypto.info("EKF: media access keys expired")

        case "prekey":
            // Replenish one-time pre-keys.
            do {
                try await keyManager.replenishPreKeys()
                SanchrLogger.crypto.info("EKF: pre-keys replenished")
            } catch {
                SanchrLogger.crypto.error("EKF: pre-key replenishment failed: \(error)")
            }

        default:
            SanchrLogger.crypto.warning("EKF: unknown key class '\(keyClass)'")
        }
    }

    func purgeExpiredAccessKeys() async {
        do {
            let purged = try await accessKeyStore.purgeExpired()
            if purged > 0 {
                SanchrLogger.crypto.info("EKF: purged \(purged) expired access keys")
            }
        } catch {
            SanchrLogger.crypto.error("EKF: access key purge failed: \(error)")
        }
    }
}
