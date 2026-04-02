import Foundation

/// Push payload structure sent by the Sanchr backend.
/// Maps to the JSON payload embedded in APNs `userInfo` under the `"sanchr"` key.
struct SanchrPushPayload: Codable, Sendable {
    /// Notification type discriminator.
    let type: PayloadType
    let conversationId: String?
    let senderId: String?
    let senderName: String?
    /// Encrypted preview text, or a generic placeholder like "New message".
    let messagePreview: String?
    let callId: String?
    /// "voice" or "video".
    let callType: String?
    let badge: Int?

    enum PayloadType: String, Codable, Sendable {
        case message
        case call
        case missedCall = "missed_call"
        case system
    }

    enum CodingKeys: String, CodingKey {
        case type
        case conversationId = "conversation_id"
        case senderId = "sender_id"
        case senderName = "sender_name"
        case messagePreview = "message_preview"
        case callId = "call_id"
        case callType = "call_type"
        case badge
    }
}

// MARK: - Convenience Initializers

extension SanchrPushPayload {
    /// Attempts to parse a `SanchrPushPayload` from APNs `userInfo`.
    /// The backend nests the custom payload under a top-level `"sanchr"` key.
    /// Falls back to parsing the root dictionary if the nested key is absent.
    static func from(userInfo: [AnyHashable: Any]) -> SanchrPushPayload? {
        let targetDict: [AnyHashable: Any]
        if let nested = userInfo["sanchr"] as? [AnyHashable: Any] {
            targetDict = nested
        } else {
            targetDict = userInfo
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: targetDict) else {
            SanchrLogger.push.error("Failed to serialize push userInfo to JSON")
            return nil
        }

        do {
            let payload = try JSONDecoder().decode(SanchrPushPayload.self, from: jsonData)
            return payload
        } catch {
            SanchrLogger.push.error("Failed to decode SanchrPushPayload: \(error.localizedDescription)")
            return nil
        }
    }
}
