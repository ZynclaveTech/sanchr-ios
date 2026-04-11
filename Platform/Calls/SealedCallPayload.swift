// Platform/Calls/SealedCallPayload.swift
import Foundation

/// The plaintext that gets Signal-encrypted into `CallOffer.encrypted_sdp_payload`
/// and `CallSignal.encrypted_sdp_answer`.
struct SealedCallPayload: Codable, Sendable {
    /// The full SDP string (offer or answer).
    let sdp: String
    /// DTLS fingerprint extracted from the SDP, e.g. "sha-256 AA:BB:CC:..."
    let dtlsFingerprint: String
    /// Unix timestamp (seconds) at which padding ends. Both sides stop padding here.
    let paddingUntil: TimeInterval
    /// Unix timestamp (seconds) at time of creation. Used for replay-attack detection.
    let timestamp: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sdp
        case dtlsFingerprint = "dtls_fingerprint"
        case paddingUntil    = "padding_until"
        case timestamp
    }
}
