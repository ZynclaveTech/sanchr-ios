import Foundation

// MARK: - vync.calling messages
// Generated from Proto/calling.proto — DO NOT EDIT

struct Vync_Calling_CallOffer: Codable, Sendable {
    var recipientID: String = ""
    /// "voice" or "video"
    var callType: String = ""
    var sdpOffer: Data = Data()
    var srtpKeyParams: Data = Data()

    enum CodingKeys: String, CodingKey {
        case recipientID = "recipient_id"
        case callType = "call_type"
        case sdpOffer = "sdp_offer"
        case srtpKeyParams = "srtp_key_params"
    }
}

struct Vync_Calling_CallResponse: Codable, Sendable {
    var callID: String = ""
    /// "ringing", "busy", "unavailable"
    var status: String = ""

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case status
    }
}

struct Vync_Calling_CallSignal: Codable, Sendable {
    var callID: String = ""
    // oneof signal
    var sdpAnswer: Data?
    var iceCandidate: Data?
    var control: Vync_Calling_CallControl?

    enum OneOf: String, Codable, Sendable {
        case sdpAnswer = "sdp_answer"
        case iceCandidate = "ice_candidate"
        case control
    }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case sdpAnswer = "sdp_answer"
        case iceCandidate = "ice_candidate"
        case control
    }

    var activeSignal: OneOf? {
        if sdpAnswer != nil { return .sdpAnswer }
        if iceCandidate != nil { return .iceCandidate }
        if control != nil { return .control }
        return nil
    }
}

struct Vync_Calling_CallControl: Codable, Sendable {
    /// "ringing", "accepted", "declined", "busy", "ended", "missed"
    var action: String = ""
}

struct Vync_Calling_EndCallRequest: Codable, Sendable {
    var callID: String = ""

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
    }
}

struct Vync_Calling_EndCallResponse: Codable, Sendable {}

struct Vync_Calling_GetCallHistoryRequest: Codable, Sendable {
    var limit: Int32 = 0
}

struct Vync_Calling_GetCallHistoryResponse: Codable, Sendable {
    var entries: [Vync_Calling_CallLogEntry] = []
}

struct Vync_Calling_CallLogEntry: Codable, Sendable, Hashable {
    var callID: String = ""
    var peerID: String = ""
    var peerName: String = ""
    /// "voice" or "video"
    var callType: String = ""
    /// "incoming" or "outgoing"
    var direction: String = ""
    /// "completed", "missed", "declined", "busy"
    var status: String = ""
    var startedAt: Int64 = 0
    var endedAt: Int64 = 0
    var durationSecs: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case peerID = "peer_id"
        case peerName = "peer_name"
        case callType = "call_type"
        case direction, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSecs = "duration_secs"
    }
}

struct Vync_Calling_GetTurnCredentialsRequest: Codable, Sendable {}

struct Vync_Calling_TurnCredentials: Codable, Sendable {
    var urls: [String] = []
    var username: String = ""
    var credential: String = ""
    var ttl: Int64 = 0
}
