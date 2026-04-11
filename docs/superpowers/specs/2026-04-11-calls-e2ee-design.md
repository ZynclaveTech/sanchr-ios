# E2EE Calls — Design Spec

**Date:** 2026-04-11
**Status:** Approved for implementation

---

## Overview

Add full end-to-end encryption to Sanchr voice and video calls. The current model uses DTLS-SRTP for media (already encrypted peer-to-peer) but the signaling plane is vulnerable: the server sees plaintext SDP offers including DTLS fingerprints, meaning a malicious server could perform a man-in-the-middle attack by swapping fingerprints. Call metadata (who called whom, when, how long) is also fully visible.

This spec describes a three-layer protection model that closes all three gaps.

---

## What the Server Will Learn After This Change

Someone using Sanchr made a call of approximately N minutes (rounded to the nearest time bucket). It cannot determine who called whom, cannot decrypt audio or video, cannot tamper with the DTLS fingerprint, and receives no SRTP key material.

---

## Three-Layer Model

### Layer 1 — Media + Fingerprint Binding (DTLS-SRTP + Signal encryption)

DTLS-SRTP already encrypts media peer-to-peer. The gap is that the server relays SDP in plaintext, allowing fingerprint substitution.

**Fix:** Alice's SDP offer is Signal-encrypted with Bob's existing session key before it ever reaches the server. The DTLS fingerprint lives inside the ciphertext — the server sees an opaque blob and cannot read or alter the fingerprint. Bob decrypts using the Signal session he already shares with Alice for messages, then verifies authenticity via Signal's sender authentication.

The encrypted payload carries: `{ sdp_offer, dtls_fingerprint, padding_until, timestamp }`.

`padding_until` is the agreed call-end time (see Layer 3). Including it in the encrypted offer means both sides are bound to the same padding target from the start.

### Layer 2 — Identity (Sealed Sender for calls)

The call initiation is wrapped in a sealed delivery token — the same mechanism already used for messages via `SealedSenderManager`. The server sees an opaque routing token and a ciphertext but does not learn who initiated the call. Only Bob can unseal the delivery certificate to learn it came from Alice.

This reuses the existing `SealedSenderManager` and delivery token infrastructure without modification.

### Layer 3 — Metadata (Duration padding)

Call duration is a strong traffic fingerprint. After the real call ends, both sides send SRTP-encrypted silence frames until the next time bucket boundary. The server observes traffic for the padded duration, not the real one.

**Buckets:** 1 min, 5 min, 15 min, 30 min, 60 min.
**Formula:** `ceil(real_duration / bucket) × bucket` where bucket is the smallest bucket ≥ real_duration.
**Padding:** SRTP-encrypted silence frames — indistinguishable from real media traffic to the server.

---

## Proto Changes (`calling.proto`)

### `CallOffer` — current state

```protobuf
message CallOffer {
  string recipient_id = 1;
  string call_type    = 2;
  bytes  sdp_offer    = 3;   // plaintext — server can read/swap fingerprint
  bytes  srtp_key_params = 4; // unused placeholder (Data())
}
```

### `CallOffer` — after this change

```protobuf
message CallOffer {
  string recipient_id        = 1;  // replaced by delivery_token for sealed routing
  string call_type           = 2;  // kept: "voice" or "video"
  reserved 3;                      // was sdp_offer — never reuse
  reserved "sdp_offer";
  reserved 4;                      // was srtp_key_params — never reuse
  reserved "srtp_key_params";
  bytes delivery_token       = 5;  // sealed sender routing token (replaces recipient_id for routing)
  bytes encrypted_sdp_payload = 6; // Signal-encrypt({ sdp_offer, dtls_fingerprint, padding_until, timestamp })
}
```

**Note on `recipient_id` (field 1):** Keep for backward compatibility during transition. Once all clients are on the E2EE version, it becomes redundant (routing happens via `delivery_token`). Mark reserved in a follow-up proto cleanup.

### `CallSignal` — `sdp_answer` also needs encryption

```protobuf
message CallSignal {
  string call_id = 1;
  oneof signal {
    reserved 2;                        // was sdp_answer — never reuse
    bytes ice_candidate         = 3;   // unchanged for now
    CallControl control         = 4;   // unchanged
    bytes encrypted_sdp_answer  = 5;   // Signal-encrypt({ sdp_answer, dtls_fingerprint, timestamp })
  }
}
```

ICE candidates remain in plaintext in this phase. They reveal network topology but not call content. Encrypting ICE is a separate future hardening pass.

---

## New Proto Message: `SealedCallPayload`

Internal type — never sent directly over the wire but useful for structured encoding before encryption:

```protobuf
// Used as the plaintext that gets Signal-encrypted into encrypted_sdp_payload
message SealedCallPayload {
  bytes   sdp             = 1;
  string  dtls_fingerprint = 2;  // hex-encoded SHA-256 of the DTLS cert
  int64   padding_until   = 3;   // unix millis — agreed padding end time
  int64   timestamp       = 4;   // unix millis — replay-attack prevention
}
```

---

## iOS Implementation Touchpoints

| Component | Change |
|-----------|--------|
| `SealedSenderManager` | No change — reused as-is for call initiation sealing |
| `CallManager` / `CallService` | Encrypt offer using Signal session before sending; decrypt answer on receive |
| `WebRTCClient` | Extract DTLS fingerprint from local cert after `createOffer()`; pass to call layer for inclusion in `SealedCallPayload` |
| Proto generated files | Regenerate after `calling.proto` changes |
| `CallDurationPaddingManager` (new) | Tracks real call end; sends SRTP silence until `padding_until`; discards incoming silence on receive end |

---

## Backward Compatibility

During the transition window, clients must handle both encrypted and unencrypted signaling:
- If `encrypted_sdp_payload` is present and non-empty → E2EE path
- If `sdp_offer` (field 3, now reserved) was populated by an old client → the server rejects or the new client rejects gracefully with a "peer does not support E2EE calls" error

This is acceptable: both sides must be on the updated build for an E2EE call. Legacy calls between old clients continue as-is until the old field is fully phased out.

---

## What This Does NOT Cover

- ICE candidate encryption (future hardening)
- Group calls (separate design required)
- Call recording detection / prevention
- Snap Camera Kit or any third-party analytics SDK (incompatible with this privacy model)
