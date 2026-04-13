// Platform/Calls/SealedCallPayload.swift
import Foundation

/// The plaintext that gets Signal-encrypted into `CallOffer.encrypted_sdp_payload`
/// and `CallSignal.encrypted_sdp_answer`.
struct SealedCallPayload: Codable, Sendable {
    /// The full SDP string (offer or answer).
    let sdp: String
    /// SDP description type. Older payloads omit this and are treated as answers in stream signaling.
    let type: String?
    /// DTLS fingerprint extracted from the SDP, e.g. "sha-256 AA:BB:CC:..."
    let dtlsFingerprint: String
    /// Unix timestamp (seconds) at time of creation. Used for replay-attack detection.
    let timestamp: TimeInterval

    init(
        sdp: String,
        dtlsFingerprint: String,
        timestamp: TimeInterval,
        type: String? = nil
    ) {
        self.sdp = sdp
        self.type = type
        self.dtlsFingerprint = dtlsFingerprint
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case sdp
        case type
        case dtlsFingerprint = "dtls_fingerprint"
        case timestamp
    }
}
