import Foundation
import UIKit
@preconcurrency import UserNotifications

/// Handles modifying notification content before display.
/// In production, the actual decryption would live in a Notification Service Extension target
/// so that E2EE message previews can be decrypted outside the main app process.
/// This class provides the shared logic used by both the main app and the extension.
final class SanchrNotificationService: Sendable {

    // MARK: - Payload Processing

    /// Process incoming push `userInfo` and return a typed payload.
    static func processPayload(_ userInfo: [AnyHashable: Any]) -> SanchrPushPayload? {
        guard let payload = SanchrPushPayload.from(userInfo: userInfo) else {
            SanchrLogger.push.warning("Unrecognized push payload format")
            return nil
        }

        SanchrLogger.push.info("Processed push payload: type=\(payload.type.rawValue)")
        return payload
    }

    // MARK: - Badge Management

    /// Update the app icon badge count.
    @MainActor
    static func updateBadgeCount(_ count: Int) async {
        if #available(iOS 16.0, *) {
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(count)
                SanchrLogger.push.info("Badge count updated to \(count)")
            } catch {
                SanchrLogger.push.error(
                    "Failed to update badge count: \(error.localizedDescription)")
            }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }

    // MARK: - Notification Clearing

    /// Remove all delivered notifications associated with a specific conversation.
    static func clearNotifications(for conversationId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let matchingIds =
                notifications
                .filter { notification in
                    let userInfo = notification.request.content.userInfo
                    if let payload = SanchrPushPayload.from(userInfo: userInfo) {
                        return payload.conversationId == conversationId
                    }
                    // Also check the threadIdentifier which we set to conversationId
                    return notification.request.content.threadIdentifier == conversationId
                }
                .map { $0.request.identifier }

            if !matchingIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: matchingIds)
                SanchrLogger.push.info(
                    "Cleared \(matchingIds.count) notifications for conversation \(conversationId.prefix(8))..."
                )
            }
        }
    }

    /// Remove all delivered notifications and reset the badge.
    static func clearAllNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()

        Task { @MainActor in
            await updateBadgeCount(0)
        }

        SanchrLogger.push.info("All notifications cleared")
    }
}
