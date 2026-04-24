# Calls Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove hardcoded `deviceId: 1` throughout the call stack so multi-device recipients can actually receive calls; wire the dead `isVideoCallEnabled` feature flag; remove the dead `AppConfiguration.turnServers` field (TURN is already server-issued via `GetTurnCredentials`).

**Architecture:**
- Proto evolution adds three opt-in fields that the iOS client *sends* and treats as authoritative when *received*. When the field is absent/zero (server hasn't rolled yet), iOS falls back to today's behavior (device `1`). This keeps iOS changes shippable before any server change.
- Outbound offer fan-out reuses the already-implemented `KeyManager.fetchUserDevices` + `SignalProtocol.encrypt(plaintext:for:deviceId:)` primitives.
- Inbound decrypt threads the caller's device id through `PushManager` → `CallManager.handleVoIPPushIncomingCall` → `CallManager.handleIncomingCallOffer` → `decryptAndValidateOffer`. Decrypted offers persist `remoteCallerDevice` so subsequent answer ciphertext is addressed to the caller's actual device.
- In-call signaling adds `answerer_device` on `CallJoin` and mirrors it on `CallSignal` so the caller knows which callee device to decrypt answers from.
- Video feature flag moves from "set but never read" to a real gate at `startCall` and `requestVideoUpgrade`; UI hides the video affordance when disabled.

**Tech Stack:** Swift 5.x, SwiftProtobuf + grpc-swift v1 (pinned to 1.27.5, generator at `Scripts/bin/protoc-gen-grpc-swift-v1`), Signal protocol (vendored `LibSignal`), CallKit / PushKit / WebRTC, XCTest.

**Server coordination:** None of the tasks below require server changes to land safely. Once the server populates `caller_device`, `device_offers[*].device_id`, and `answerer_device`, multi-device calls begin working end-to-end with no further iOS release. Until then, iOS writes the new fields outbound and falls back to device `1` when reading. A server-side TODO list is appended at the end of this plan.

**Working directory convention:** All shell commands in this plan assume `cwd = ios/Sanchr-iOS/` (the git repo root). All file paths (`Platform/Calls/...`, `SanchrShared/...`, `Tests/UnitTests/...`) are relative to that root.

**Verification (every commit):**

```bash
# Focused iOS test run — must be green before committing
xcodebuild -workspace Sanchr.xcworkspace \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests \
  -skipPackagePluginValidation \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test 2>&1 | tail -30

# Before merging the phase — full unit suite
xcodebuild -workspace Sanchr.xcworkspace \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test 2>&1 | tail -60
```

Do not report complete unless both commands exit 0.

---

## File Structure

| File | Role | Sub-phases |
|------|------|-----------|
| `SanchrShared/Config/AppConfiguration.swift` | Config container; kill `turnServers`; keep `isVideoCallEnabled` (wired in F). | A, F |
| `Proto/messaging.proto` | Add `caller_device` to `CallOfferEvent`. | B |
| `Proto/calling.proto` | Add `DeviceCallOffer`, add `repeated device_offers` to `CallOffer`, add `answerer_device` to `CallJoin` and `CallSignal`. | B |
| `SanchrShared/Generated/messaging.pb.swift` | Regenerated. | B |
| `SanchrShared/Generated/calling.pb.swift` | Regenerated. | B |
| `Platform/Notifications/PushManager.swift` | Parse `caller_device` from VoIP push dictionary; forward to `CallManager`. | C |
| `Platform/Calls/CallManager.swift` | Thread device ids; store `remoteCallerDevice`; fan-out offer; gate video. | C, D, E, F |
| `Features/Calls/Data/CallDataSource.swift` | New signature for `initiateCall` that carries `deviceOffers`. | D |
| `SanchrShared/Crypto/SignalProtocol.swift` | Add `encryptCallOffers(plaintext:recipientId:)` → `[Sanchr_Calling_DeviceCallOffer]`. | D |
| `App/DependencyContainer.swift` | Pass `AppConfiguration.current.isVideoCallEnabled` into `CallManager`; inject `localDeviceId` resolver. | E, F |
| `Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift` | Cover every behavior below. | C, D, E, F |
| `Tests/UnitTests/TestDoubles.swift` | Extend `MockSignalManager` with new protocol method. | D |
| `Features/Calls/Presentation/CallsListView.swift` (or video button host) | Hide video CTA when flag off. | F |

Each sub-phase touches ≤5 files and ends with a commit, per `CLAUDE.md` section 2 (Phased Execution).

---

## Sub-phase A — Step 0 cleanup

Dead code first, per `CLAUDE.md` section 1. Two trivial commits before any structural work starts.

### Task A1: Remove dead `AppConfiguration.turnServers`

**Files:**
- Modify: `SanchrShared/Config/AppConfiguration.swift`

**Rationale:** `turnServers` is declared (line 21), populated in every factory (`.development`, `.dev`, `.staging`, `.production`) and never read. `buildIceServers` in `CallManager.swift:1656-1673` reads TURN from the gRPC `GetTurnCredentials` response, not from `AppConfiguration`. The field is misleading — deleting it removes the only surviving reference to the "TODO: Configure production TURN servers" comment, which should instead live as a server-side issue.

- [ ] **Step 1: Write the failing test**

Create a compile-time test by adding, at the bottom of `Tests/UnitTests/AppConfigurationTests.swift` (create the file if it does not exist):

```swift
// Tests/UnitTests/AppConfigurationTests.swift
import XCTest
@testable import SanchrShared

final class AppConfigurationTests: XCTestCase {
    func test_production_hasNoClientSideTurnServerList() {
        // TURN credentials come exclusively from the server's GetTurnCredentials RPC.
        // AppConfiguration must not carry a static TURN list — that field was dead
        // code that misrepresented where TURN configuration lives.
        let mirror = Mirror(reflecting: AppConfiguration.production)
        XCTAssertFalse(
            mirror.children.contains(where: { $0.label == "turnServers" }),
            "AppConfiguration must not expose a turnServers field — TURN is server-issued"
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/AppConfigurationTests \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -20
```

Expected: FAIL (field still present in the mirror).

- [ ] **Step 3: Delete the dead field**

Edit `SanchrShared/Config/AppConfiguration.swift`:

1. Remove the property at line 21: `public let turnServers: [String]`.
2. Remove the parameter at line 47 (`turnServers: [String],`) and the assignment at line 63 (`self.turnServers = turnServers`).
3. Remove the four `turnServers:` lines inside the factories (`development` ~line 91, `dev` ~line 107, `staging` ~line 123, `production` ~lines 142-144). The empty `[]` in dev/staging and the `// TODO: Configure production TURN servers` block in production all go away.
4. Add a one-line doc comment above the `stunServers` field clarifying source-of-truth:

```swift
/// STUN-only fallback list baked into the client. TURN credentials are fetched
/// per-call via `CallSignalingService.GetTurnCredentials` and MUST NOT be
/// hard-coded here — rotating credentials in a release is a server ops failure.
public let stunServers: [String]
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as step 2. Expected: PASS.

- [ ] **Step 5: Full build + existing suite sanity check**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If any call site still references `turnServers`, grep finds zero (per rule 10, do all of: `.turnServers`, `turnServers:`, `"turnServers"`):

```bash
# All three must return zero matches
grep -r '\.turnServers' . --include='*.swift' | wc -l
grep -r 'turnServers:' . --include='*.swift' | wc -l
grep -r '"turnServers"' . --include='*.swift' | wc -l
```

- [ ] **Step 6: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add SanchrShared/Config/AppConfiguration.swift \
        Tests/UnitTests/AppConfigurationTests.swift
git commit -m "chore(config): remove dead AppConfiguration.turnServers

TURN credentials are fetched per-call via CallSignalingService.GetTurnCredentials.
The static turnServers list was never read anywhere in the client — dropping it
removes a misleading configuration surface and the stale production TODO."
```

---

### Task A2: Note `isVideoCallEnabled` as unwired dead code

**Files:**
- Modify: `SanchrShared/Config/AppConfiguration.swift` (one-line comment)

**Rationale:** `isVideoCallEnabled` is set to `false` in `.production` but never consulted. Today, video calls work in production identical to every other environment. The flag is wired for real in Sub-phase F; this task adds a `FIXME` that references Sub-phase F so a reader doesn't misread `false` as an enforced gate. This is the only safe "partial fix" — deleting the flag here would lose information, and wiring it here creates churn that conflicts with F's tests.

- [ ] **Step 1: Edit the field declaration**

In `SanchrShared/Config/AppConfiguration.swift`, replace the declaration of `isVideoCallEnabled`:

```swift
/// FIXME(calls/P0-F): Currently set per-environment but never read by any code path.
/// Video calls work in ALL environments today. Sub-phase F of the calls-hardening
/// plan wires this flag into `CallManager.startCall` and `requestVideoUpgrade`,
/// and into the chat/call UI video CTAs. Do not add new reads of this flag until
/// Sub-phase F lands — doing so splits the gate across two places and guarantees
/// drift.
public let isVideoCallEnabled: Bool
```

- [ ] **Step 2: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add SanchrShared/Config/AppConfiguration.swift
git commit -m "docs(config): mark isVideoCallEnabled as unwired until sub-phase F"
```

---

## Sub-phase B — Proto evolution

Three small additive changes, then one regeneration. All fields are optional scalars or repeated messages — safe to ship ahead of server, safe to ignore server-side until it's ready.

### Task B1: Extend proto definitions

**Files:**
- Modify: `Proto/messaging.proto` — add `int32 caller_device` to `CallOfferEvent`.
- Modify: `Proto/calling.proto` — add `DeviceCallOffer`, `repeated DeviceCallOffer device_offers`, `int32 answerer_device` on `CallJoin`, `int32 answerer_device` on `CallSignal`.

- [ ] **Step 1: Edit `Proto/messaging.proto`**

Replace the `CallOfferEvent` message (currently at lines 66-73):

```proto
message CallOfferEvent {
  string call_id = 1;
  string caller_id = 2;
  string call_type = 3;
  bytes sdp_offer = 4;
  bytes srtp_key_params = 5;
  bytes encrypted_sdp_payload = 6;  // Signal-encrypt(SealedCallPayload JSON)
  // Device id of the caller for Signal session addressing. When zero/absent,
  // iOS falls back to device 1 for backward compatibility with pre-multi-device
  // servers. Populated by the server from the sender_device of the underlying
  // EncryptedEnvelope that carried the offer.
  int32 caller_device = 7;
}
```

- [ ] **Step 2: Edit `Proto/calling.proto`**

Replace `CallOffer` (currently at lines 12-21) and `CallSignal` + `CallJoin` (lines 28-42):

```proto
message CallOffer {
  string recipient_id = 1;    // kept for server backward compat; unused when delivery_token is set
  string call_type = 2;       // "voice" or "video"
  reserved 3;                 // was sdp_offer — do not reuse
  reserved "sdp_offer";
  reserved 4;                 // was srtp_key_params — do not reuse
  reserved "srtp_key_params";
  bytes delivery_token = 5;         // sealed sender routing token
  bytes encrypted_sdp_payload = 6 [deprecated = true];  // legacy single-device path
  // One encrypted payload per recipient device. Preferred over
  // `encrypted_sdp_payload` when non-empty. Server fans each entry out to the
  // matching device. If empty, server falls back to `encrypted_sdp_payload`
  // addressed to device 1.
  repeated DeviceCallOffer device_offers = 7;
}

message DeviceCallOffer {
  int32 device_id = 1;
  bytes encrypted_sdp_payload = 2;  // Signal-encrypt(SealedCallPayload JSON) for this device
}

message CallSignal {
  string call_id = 1;
  reserved 2;                       // was sdp_answer — do not reuse
  reserved "sdp_answer";
  oneof signal {
    bytes ice_candidate = 3;          // unchanged
    CallControl control = 4;          // unchanged
    bytes encrypted_sdp_answer = 5;   // Signal-encrypt(SealedCallPayload JSON)
    CallJoin join = 6;                // stream join; consumed by server, not relayed
  }
  // Device id of the peer whose message this signal carries. For
  // encrypted_sdp_answer, this is the answerer's device (populated by server
  // from CallJoin.answerer_device). For ice_candidate and control, this is
  // informational. When zero/absent, iOS falls back to device 1.
  int32 peer_device = 7;
}

message CallJoin {
  string role = 1;             // "caller" or "callee"
  // Device id the joining client is answering from. Server mirrors this onto
  // CallSignal.peer_device for the caller side so the caller can decrypt
  // answers with the correct Signal session.
  int32 answerer_device = 2;
}
```

- [ ] **Step 3: Sanity-check the proto edits compile with `protoc --dry-run`**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
protoc --proto_path=Proto --descriptor_set_out=/dev/null Proto/messaging.proto Proto/calling.proto
```

Expected: exits 0 with no output. If you see a field-number collision or syntax error, fix it before regenerating Swift code.

- [ ] **Step 4: Commit the proto changes only**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Proto/messaging.proto Proto/calling.proto
git commit -m "proto(calls): add caller_device, device_offers, answerer_device

All three fields are optional and additive — servers may ignore them until they
ship matching logic. iOS will read them when present and fall back to device 1
when absent, so this change is safe to land ahead of any backend work.

caller_device on CallOfferEvent lets the callee decrypt against the caller's
actual Signal session. device_offers on CallOffer lets the caller fan out per
recipient device. answerer_device on CallJoin (mirrored on CallSignal.peer_device)
lets the caller decrypt answers from a specific callee device."
```

---

### Task B2: Regenerate Swift protobuf code

**Files:**
- Modify (bulk via script): `SanchrShared/Generated/messaging.pb.swift`, `.../calling.pb.swift`, `.../messaging.grpc.swift`, `.../calling.grpc.swift`.

- [ ] **Step 1: Run the regeneration script**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
./Scripts/generate-protos.sh
```

Expected output tail: `Done. Generated files in .../SanchrShared/Generated`.

- [ ] **Step 2: Review the diff and revert cosmetic-only drift**

```bash
git diff --stat SanchrShared/Generated/
git diff SanchrShared/Generated/messaging.pb.swift | head -80
git diff SanchrShared/Generated/calling.pb.swift | head -120
```

Per the header comment in `Scripts/generate-protos.sh`, `ClientMetadata.Methods` visibility may flip `internal` → `public`. Revert that drift per file with `git checkout -p` unless the phase needs it. The only semantic changes you want in this commit are: new properties `callerDevice`, `deviceOffers`, `peerDevice`, `answererDevice`, the new `Sanchr_Calling_DeviceCallOffer` struct, and their `case` entries in the `_ProtobufMessage` conformance.

- [ ] **Step 3: Build to verify the generated code compiles against the existing call sites**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. Existing call sites that still read `.encryptedSdpPayload` compile fine because the field remains on the generated struct (the `deprecated=true` is a proto-level hint only — SwiftProtobuf v1 does not emit Swift-level deprecation attributes, so no new compiler warnings appear).

- [ ] **Step 4: Commit the regenerated code separately**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add SanchrShared/Generated/
git commit -m "proto(gen): regenerate pb.swift for calls proto additions"
```

---

## Sub-phase C — Inbound: thread `caller_device` end-to-end

Goal: callee decrypts offers against the caller's *actual* device, not `1`. Ships behind a fallback, so works even when the server still sends `caller_device = 0`.

### Task C1: Add `remoteCallerDevice` state to `CallManager`

**Files:**
- Modify: `Platform/Calls/CallManager.swift` (state declaration only)

- [ ] **Step 1: Write the failing test**

Append to `Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift`:

```swift
    // MARK: - Multi-device decrypt

    /// After a successful incoming-offer decrypt, the CallManager must remember
    /// which sender device the ciphertext came from so subsequent answer
    /// ciphertext can be encrypted for that exact Signal session.
    func test_handleIncomingCallOffer_persistsRemoteCallerDevice() async throws {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager
        )

        // Build an offer event with caller_device = 7 — the field added in sub-phase B.
        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )
        var offerEvent = makeOfferEvent(payload: payload, callerId: "alice")
        offerEvent.callerDevice = 7

        let outcome = await callManager.handleIncomingCallOffer(offerEvent)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(callManager.remoteCallerDevice, 7,
            "remoteCallerDevice must hold the sender device id after a decrypt succeeds")
    }

    /// When the server hasn't populated caller_device yet (value = 0), iOS must
    /// fall back to device 1 so legacy offers still round-trip.
    func test_handleIncomingCallOffer_fallsBackToDeviceOneWhenCallerDeviceAbsent() async throws {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager
        )

        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )
        let offerEvent = makeOfferEvent(payload: payload, callerId: "alice")
        // offerEvent.callerDevice stays 0 (default) — simulates legacy server.

        let outcome = await callManager.handleIncomingCallOffer(offerEvent)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(callManager.remoteCallerDevice, 1,
            "must fall back to device 1 when caller_device is absent (0)")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests/test_handleIncomingCallOffer_persistsRemoteCallerDevice \
  -only-testing:SanchrTests/CallManagerE2EETests/test_handleIncomingCallOffer_fallsBackToDeviceOneWhenCallerDeviceAbsent \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -30
```

Expected: compile error on `callManager.remoteCallerDevice` (field doesn't exist yet).

- [ ] **Step 3: Add the state**

In `Platform/Calls/CallManager.swift`, in the `// MARK: - Internal State` block (~line 114), add:

```swift
    /// Signal device id of the current peer for decrypt/encrypt addressing.
    /// Set during incoming-offer decrypt from `CallOfferEvent.callerDevice`;
    /// read during outgoing-answer encrypt and during in-call signal decrypt.
    /// Zero means "not yet known" — callers must substitute a sensible default
    /// (today: device 1) when building a `ProtocolAddress`.
    private(set) var remoteCallerDevice: Int32 = 0
```

This must be placed after `private var pendingSdpOffer: Data?` (~line 117) and before `private var paddingManager = CallDurationPaddingManager()` (~line 118). `private(set)` exposes it for the test assertions via `@testable import Sanchr`.

- [ ] **Step 4: Run the tests — still failing on the decrypt path**

The state exists now but isn't populated. The tests should now fail on assertion (not compile error). This is expected; it's covered by Task C3.

- [ ] **Step 5: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Platform/Calls/CallManager.swift \
        Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift
git commit -m "feat(calls): stub remoteCallerDevice state + failing tests

State holder for the caller's Signal device id on the callee side. Tests are
intentionally red — wired up in the following tasks of sub-phase C."
```

---

### Task C2: Decrypt using `offer.callerDevice` with fallback

**Files:**
- Modify: `Platform/Calls/CallManager.swift` (`decryptAndValidateOffer`, `handleIncomingCallOffer`)

- [ ] **Step 1: Re-read the file before editing (CLAUDE.md rule 9)**

```bash
# Verify current content
grep -n 'decryptAndValidateOffer\|senderDevice: 1\|deviceId: 1' \
  Platform/Calls/CallManager.swift
```

Expected lines: 215, 217, 586, 894, 1316, 1353, 1638 (the last being inside `decryptAndValidateOffer`).

- [ ] **Step 2: Change `decryptAndValidateOffer` signature + body**

In `CallManager.swift`, replace the function at lines 1627-1652:

```swift
    /// Decrypts and validates an incoming call offer.
    /// - Returns: The plaintext SDP string on success.
    /// - Throws: `AppError.decryptionFailed` when the Signal decrypt fails,
    ///   the payload is stale, or the embedded DTLS fingerprint does not
    ///   match the SDP's. All failures log the reason and do not surface the
    ///   raw decrypt error to the caller.
    private func decryptAndValidateOffer(
        _ offer: Sanchr_Messaging_CallOfferEvent,
        maxAgeSeconds: TimeInterval
    ) async throws -> String {
        guard !offer.encryptedSdpPayload.isEmpty else {
            throw AppError.decryptionFailed(reason: "encrypted call offer payload is empty")
        }
        // caller_device is populated by multi-device-aware servers; legacy
        // servers leave it at 0. When absent, fall back to device 1 so pre-
        // multi-device deployments keep working exactly as before.
        let senderDevice: Int32 = offer.callerDevice > 0 ? offer.callerDevice : 1
        let plaintext = try await signalManager.decrypt(
            ciphertext: offer.encryptedSdpPayload,
            from: offer.callerID,
            senderDevice: senderDevice
        )
        let sealedPayload = try JSONDecoder().decode(SealedCallPayload.self, from: plaintext)
        let age = abs(Date().timeIntervalSince1970 - sealedPayload.timestamp)
        guard age <= maxAgeSeconds else {
            throw AppError.decryptionFailed(reason: "stale call offer age=\(Int(age))s")
        }
        let offerDesc = RTCSessionDescription(type: .offer, sdp: sealedPayload.sdp)
        guard let sdpFingerprint = WebRTCClient.extractDtlsFingerprint(from: offerDesc),
              sdpFingerprint == sealedPayload.dtlsFingerprint
        else {
            throw AppError.decryptionFailed(reason: "DTLS fingerprint missing or mismatched")
        }
        // Persist the sender device so the answer we send back encrypts for
        // the exact session we just decrypted from, not device 1.
        self.remoteCallerDevice = senderDevice
        return sealedPayload.sdp
    }
```

- [ ] **Step 3: Replace the `resetSession(... deviceId: 1)` on decrypt failure**

In `handleIncomingCallOffer` (line 1353), replace:

```swift
            try? signalManager.resetSession(with: offer.callerID, deviceId: 1)
```

with:

```swift
            let resetDevice: Int32 = offer.callerDevice > 0 ? offer.callerDevice : 1
            try? signalManager.resetSession(with: offer.callerID, deviceId: resetDevice)
```

And the same replacement at line 1316 inside the `"Stream: SDP decryption failed for pending call"` branch.

- [ ] **Step 4: Re-read the file after editing (CLAUDE.md rule 9)**

```bash
grep -n 'deviceId: 1\|senderDevice: 1' \
  Platform/Calls/CallManager.swift
```

Expected after this task: lines 215, 217, 556, 586, 894 remain. The VoIP-push site (556, 586) is covered in Task C3; the outbound sites (215, 217, 894) are covered in Sub-phase D. Lines 1316, 1353, 1638 are gone.

- [ ] **Step 5: Run the tests**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -40
```

Expected: `test_handleIncomingCallOffer_persistsRemoteCallerDevice` and `test_handleIncomingCallOffer_fallsBackToDeviceOneWhenCallerDeviceAbsent` PASS. All pre-existing tests still PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Platform/Calls/CallManager.swift
git commit -m "fix(calls): decrypt incoming offers against caller's actual device

Reads caller_device from CallOfferEvent and uses it to address the Signal
session. Falls back to device 1 when absent so it's safe to ship ahead of the
server-side change that starts populating the field. Persists the resolved
device id on CallManager.remoteCallerDevice so the answer encrypts against the
same session — previously the answer re-encrypted for device 1 regardless of
which sender device actually reached us."
```

---

### Task C3: Thread `callerDevice` through the VoIP-push path

**Files:**
- Modify: `Platform/Calls/CallManager.swift` (`handleVoIPPushIncomingCall` signature + decrypt call)
- Modify: `Platform/Notifications/PushManager.swift` (parse `caller_device`, forward to handler)

- [ ] **Step 1: Write the failing test**

Append to `CallManagerE2EETests.swift`:

```swift
    /// VoIP push arrives with the caller's device id — the async SDP decrypt
    /// Task must use it instead of hardcoding device 1.
    func test_handleVoIPPushIncomingCall_usesCallerDeviceForDecrypt() async throws {
        final class RecordingSignalManager: SignalProtocolManagerProtocol, @unchecked Sendable {
            let localUserId: String = "test-local-user"
            var lastSenderDevice: Int32 = -1
            func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data { plaintext }
            func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data {
                lastSenderDevice = senderDevice
                // Return a valid SealedCallPayload JSON so the async decrypt Task completes
                // without throwing — we only care about capturing senderDevice.
                let payload = SealedCallPayload(
                    sdp: "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n",
                    dtlsFingerprint: "sha-256 DE:AD:BE:EF",
                    timestamp: Date().timeIntervalSince1970
                )
                return try JSONEncoder().encode(payload)
            }
            func establishSession(with userId: String, deviceId: Int32) async throws {}
            func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
            func hasSession(with userId: String) -> Bool { true }
            func encryptForAllDevices(plaintext: Data, recipientId: String) async throws -> [Sanchr_Messaging_DeviceMessage] { [] }
            func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { envelope.ciphertext }
            func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
                throw AppError.decryptionFailed(reason: "not used")
            }
            func resetSession(with userId: String, deviceId: Int32) throws {}
            func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
            func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
            func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
            func markIdentityVerified(userId: String) {}
            func isIdentityVerified(userId: String) -> Bool { false }
            func localIdentityKeyData() throws -> Data { Data() }
            func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
        }
        let signalManager = RecordingSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = await MainActor.run {
            CallManager(
                webRTCClient: webRTCClient,
                callService: callService,
                signalManager: signalManager
            )
        }

        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )

        await MainActor.run {
            callManager.handleVoIPPushIncomingCall(
                callId: "push-call-id",
                callerId: "alice",
                callerDevice: 9,
                callType: "voice",
                encryptedSdpPayload: payload
            )
        }

        // Give the async decrypt Task a chance to run.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(signalManager.lastSenderDevice, 9,
            "VoIP push decrypt must address the caller's device id, not hardcode 1")
    }
```

- [ ] **Step 2: Run to confirm it fails**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests/test_handleVoIPPushIncomingCall_usesCallerDeviceForDecrypt \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -15
```

Expected: compile error (no `callerDevice:` parameter in `handleVoIPPushIncomingCall`).

- [ ] **Step 3: Add `callerDevice` parameter to `CallManager.handleVoIPPushIncomingCall`**

In `CallManager.swift:450-454`, change the signature to:

```swift
    func handleVoIPPushIncomingCall(
        callId: String,
        callerId: String,
        callerDevice: Int32,
        callType: String,
        encryptedSdpPayload: Data
    ) {
```

And inside the async Task block at line 553, replace `senderDevice: 1` with `senderDevice: callerDevice > 0 ? callerDevice : 1`. Also replace the reset-session fallback at line 586:

```swift
                try? self.signalManager.resetSession(
                    with: callerId,
                    deviceId: callerDevice > 0 ? callerDevice : 1
                )
```

And persist the resolved device after the fingerprint check succeeds (just before line 579 `self.pendingSdpOffer = Data(...)`):

```swift
                self.remoteCallerDevice = callerDevice > 0 ? callerDevice : 1
                self.pendingSdpOffer = Data(sealedPayload.sdp.utf8)
```

- [ ] **Step 4: Update `PushManager.pushRegistry(...)` to parse and forward `caller_device`**

In `Platform/Notifications/PushManager.swift:576-605`, replace the body of `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)`:

```swift
    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        defer { completion() }
        guard type == .voIP else { return }

        let dict = payload.dictionaryPayload
        guard
            let callId = dict["call_id"] as? String, !callId.isEmpty,
            let callerId = dict["caller_id"] as? String, !callerId.isEmpty
        else {
            SanchrLogger.push.error("VoIP push: missing required fields (call_id, caller_id)")
            return
        }

        let callType = (dict["call_type"] as? String) ?? "voice"
        let encSdpB64 = (dict["encrypted_sdp_payload"] as? String) ?? ""
        let encSdpData = Data(base64Encoded: encSdpB64) ?? Data()

        // caller_device may arrive as an NSNumber, an Int, or a numeric string
        // depending on how the server serializes the payload. Accept all three;
        // fall back to 0 when absent so CallManager's own fallback logic applies.
        let callerDevice: Int32
        if let n = dict["caller_device"] as? NSNumber {
            callerDevice = n.int32Value
        } else if let i = dict["caller_device"] as? Int {
            callerDevice = Int32(i)
        } else if let s = dict["caller_device"] as? String, let parsed = Int32(s) {
            callerDevice = parsed
        } else {
            callerDevice = 0
        }

        SanchrLogger.push.info(
            "VoIP push: incoming \(callType) call \(callId) from \(callerId) device=\(callerDevice) sdp_in_push=\(!encSdpData.isEmpty)")

        incomingVoIPCallHandler?(callId, callerId, callerDevice, callType, encSdpData)
    }
```

- [ ] **Step 5: Update the `incomingVoIPCallHandler` type + every call site**

In `PushManager.swift`, find the property declaration for `incomingVoIPCallHandler` (search for `incomingVoIPCallHandler:` in the file). Change the closure type to `((String, String, Int32, String, Data) -> Void)?` and update the doc-comment.

Find the single consumer — `App/DependencyContainer.swift` wires this when it constructs `PushManager`. Search and update:

```bash
grep -n 'incomingVoIPCallHandler' App/DependencyContainer.swift
```

At each assignment site, change the closure from `{ callId, callerId, callType, encSdp in ... }` to `{ callId, callerId, callerDevice, callType, encSdp in callManager.handleVoIPPushIncomingCall(callId: callId, callerId: callerId, callerDevice: callerDevice, callType: callType, encryptedSdpPayload: encSdp) }`.

Per CLAUDE.md rule 10, also grep for indirect or test-only references:

```bash
grep -rn 'incomingVoIPCallHandler' . --include='*.swift'
```

If `PushManagerTests.swift` (or similar) exists and hits this callback, update its fixture tuple order too.

- [ ] **Step 6: Build + full focused test suite**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build 2>&1 | tail -20

xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED and all `CallManagerE2EETests` pass, including the new one.

- [ ] **Step 7: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Platform/Calls/CallManager.swift \
        Platform/Notifications/PushManager.swift \
        App/DependencyContainer.swift \
        Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift
git commit -m "fix(calls): thread caller_device through VoIP push path

PushManager reads caller_device from the APNs dictionary (accepting NSNumber /
Int / numeric-string forms) and hands it to CallManager. The async SDP-decrypt
Task uses it for both the successful decrypt and the self-healing
resetSession() fallback. Falls back to device 1 when the push payload omits
caller_device so legacy servers keep working."
```

---

## Sub-phase D — Outbound: fan-out offer per recipient device

Goal: caller encrypts one ciphertext per recipient device and ships them inside `CallOffer.device_offers`. Legacy `encryptedSdpPayload` keeps populating the device-1 ciphertext so mixed-version servers still succeed.

### Task D1: Add `encryptCallOffers` to `SignalProtocolManagerProtocol`

**Files:**
- Modify: `SanchrShared/Crypto/SignalProtocol.swift` (protocol + default impl)
- Modify: `Tests/UnitTests/TestDoubles.swift` (extend any stub types)
- Modify: `Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift` (extend `MockSignalManager`)

- [ ] **Step 1: Write the failing test**

Append to `CallManagerE2EETests.swift`:

```swift
    /// startCall must populate CallOffer.device_offers with one entry per
    /// recipient device, each encrypted independently. The legacy
    /// encrypted_sdp_payload field stays populated for backward compat,
    /// mirroring the device-1 ciphertext.
    func test_startCall_fansOutOfferToAllRecipientDevices() async throws {
        final class MultiDeviceSignalManager: SignalProtocolManagerProtocol, @unchecked Sendable {
            let localUserId: String = "test-local-user"
            func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data {
                // Tag each ciphertext with its target device so the test can assert addressing.
                var tagged = Data([0xC0, UInt8(truncatingIfNeeded: deviceId)])
                tagged.append(plaintext)
                return tagged
            }
            func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data { ciphertext }
            func establishSession(with userId: String, deviceId: Int32) async throws {}
            func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
            func hasSession(with userId: String) -> Bool { true }
            func encryptForAllDevices(plaintext: Data, recipientId: String) async throws -> [Sanchr_Messaging_DeviceMessage] { [] }
            func encryptCallOffers(plaintext: Data, recipientId: String) async throws -> [Sanchr_Calling_DeviceCallOffer] {
                // .map cannot be async without swift-async-algorithms — use a for-loop.
                var out: [Sanchr_Calling_DeviceCallOffer] = []
                for deviceId in [Int32(1), Int32(3), Int32(7)] {
                    let ct = try await encrypt(plaintext: plaintext, for: recipientId, deviceId: deviceId)
                    var entry = Sanchr_Calling_DeviceCallOffer()
                    entry.deviceID = deviceId
                    entry.encryptedSdpPayload = ct
                    out.append(entry)
                }
                return out
            }
            func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { envelope.ciphertext }
            func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
                throw AppError.decryptionFailed(reason: "not used")
            }
            func resetSession(with userId: String, deviceId: Int32) throws {}
            func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
            func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
            func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
            func markIdentityVerified(userId: String) {}
            func isIdentityVerified(userId: String) -> Bool { false }
            func localIdentityKeyData() throws -> Data { Data() }
            func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
        }

        // Rather than subclass MockCallSignalingService (which is `private final`
        // in this file), add a capture hook and pin the captured request from the
        // closure. This keeps the mock's final declaration intact.
        final class CaptureBox: @unchecked Sendable {
            var offer: Sanchr_Calling_CallOffer?
        }
        let capture = CaptureBox()

        let signalManager = MultiDeviceSignalManager()
        let callService = MockCallSignalingService()
        callService.onInitiateCall = { request in capture.offer = request }
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager
        )

        do {
            try await callManager.startCall(recipientId: "bob", recipientName: "Bob", isVideo: false)
        } catch {
            throw XCTSkip("WebRTC/CallKit unavailable in this simulator: \(error.localizedDescription)")
        }

        guard let offer = capture.offer else {
            return XCTFail("initiateCall must have been invoked exactly once")
        }

        XCTAssertEqual(offer.deviceOffers.count, 3,
            "device_offers must carry one entry per recipient device (expected 3, got \(offer.deviceOffers.count))")
        XCTAssertEqual(Set(offer.deviceOffers.map(\.deviceID)), [1, 3, 7],
            "device_offers must cover every device returned by encryptCallOffers")
        // Back-compat: encrypted_sdp_payload mirrors the device-1 ciphertext so
        // pre-multi-device servers still route the call.
        let deviceOneCiphertext = offer.deviceOffers.first(where: { $0.deviceID == 1 })?.encryptedSdpPayload
        XCTAssertEqual(offer.encryptedSdpPayload, deviceOneCiphertext,
            "legacy encrypted_sdp_payload must mirror the device-1 ciphertext for backward compat")
    }
```

Note the `CapturingCallService` inherits from `MockCallSignalingService` — add `open class` (or expose `initiateCall` as `open`) to the existing mock if subclassing from inside the same test file doesn't compile because of the `final` marker. If that's blocking, change `MockCallSignalingService` from `final` to non-final in the same commit.

- [ ] **Step 2: Extend the protocol in `SignalProtocol.swift`**

In `SanchrShared/Crypto/SignalProtocol.swift` at line ~22 (the protocol), add:

```swift
    /// Encrypts `plaintext` once per known recipient device and returns a
    /// ready-to-ship `DeviceCallOffer` list. Caller sets the resulting list
    /// as `CallOffer.device_offers`; the server fans each entry to the
    /// matching device's inbox.
    func encryptCallOffers(plaintext: Data, recipientId: String) async throws
        -> [Sanchr_Calling_DeviceCallOffer]
```

In the implementation class (the same file, look for the `extension SignalProtocolManager` or similar after line ~140), add the default implementation:

```swift
    public func encryptCallOffers(plaintext: Data, recipientId: String) async throws
        -> [Sanchr_Calling_DeviceCallOffer]
    {
        let deviceIds = try await keyManager.fetchUserDevices(recipientId: recipientId)
        SanchrLogger.crypto.info(
            "encryptCallOffers: fanning out to \(deviceIds.count) device(s) for \(recipientId.prefix(8))...: \(deviceIds)")

        var results: [Sanchr_Calling_DeviceCallOffer] = []
        results.reserveCapacity(deviceIds.count)
        for deviceId in deviceIds {
            // Call offers MUST always use a fresh PreKeySignalMessage so an
            // out-of-sync session on either side self-heals. Reset the
            // per-device session before encrypting — same rationale as the
            // existing single-device path.
            try? resetSession(with: recipientId, deviceId: deviceId)
            let ct = try await encrypt(plaintext: plaintext, for: recipientId, deviceId: deviceId)
            var entry = Sanchr_Calling_DeviceCallOffer()
            entry.deviceID = deviceId
            entry.encryptedSdpPayload = ct
            results.append(entry)
        }
        return results
    }
```

- [ ] **Step 3: Extend test stubs**

**3a.** Open `Tests/UnitTests/TestDoubles.swift` and locate every type that conforms to `SignalProtocolManagerProtocol` (grep `: SignalProtocolManagerProtocol`). For each, add:

```swift
    func encryptCallOffers(plaintext: Data, recipientId: String) async throws
        -> [Sanchr_Calling_DeviceCallOffer] { [] }
```

**3b.** Also update the inline `MockSignalManager` at the top of `CallManagerE2EETests.swift` (~line 11) with the same stub.

**3c.** Add an `onInitiateCall` capture hook to `MockCallSignalingService` in `CallManagerE2EETests.swift` (so the new test can capture the outbound `CallOffer` without subclassing the `final` mock). Locate the `initiateCall(_:callOptions:)` method (~line 87) and change its body to:

```swift
    var onInitiateCall: ((Sanchr_Calling_CallOffer) -> Void)?

    func initiateCall(
        _ request: Sanchr_Calling_CallOffer,
        callOptions: CallOptions? = nil
    ) async throws -> Sanchr_Calling_CallResponse {
        onInitiateCall?(request)
        var response = Sanchr_Calling_CallResponse()
        response.callID = "test-call-id"
        response.status = "ringing"
        return response
    }
```

(The new stored property goes at the top of the class body, alongside `var defaultCallOptions` at line 54.)

- [ ] **Step 4: Run — expect the new test to fail at the `startCall` side**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests/test_startCall_fansOutOfferToAllRecipientDevices \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -20
```

Expected: FAIL — `offer.deviceOffers.count == 0` because `startCall` still populates only `encryptedSdpPayload`.

- [ ] **Step 5: Commit the protocol change**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add SanchrShared/Crypto/SignalProtocol.swift \
        Tests/UnitTests/TestDoubles.swift \
        Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift
git commit -m "feat(crypto): add encryptCallOffers for per-device call fan-out

Reuses keyManager.fetchUserDevices + encrypt/resetSession to produce one
DeviceCallOffer per recipient device. Wire-up at the CallManager side comes
next — this commit only adds the protocol method and its stubs in test
doubles, plus a red test that demands CallOffer.device_offers be populated."
```

---

### Task D2: Use `encryptCallOffers` inside `CallManager.startCall`

**Files:**
- Modify: `Platform/Calls/CallManager.swift:174-269`

- [ ] **Step 1: Replace the encrypt-and-send block**

In `CallManager.swift`, replace lines 198-228 (from `// 5. Encrypt offer for E2EE` through the `let response = try await callService.initiateCall(callOffer)` line) with:

```swift
        // 5. Encrypt offer for E2EE — one ciphertext per recipient device.
        guard let fingerprint = WebRTCClient.extractDtlsFingerprint(from: offer) else {
            throw AppError.callConnectionFailed
        }
        let payload = SealedCallPayload(
            sdp: offer.sdp,
            dtlsFingerprint: fingerprint,
            timestamp: Date().timeIntervalSince1970
        )
        let payloadData = try JSONEncoder().encode(payload)

        // Fresh PreKeySignalMessage per device is handled inside
        // encryptCallOffers (it resets each per-device session before encrypt).
        let deviceOffers = try await signalManager.encryptCallOffers(
            plaintext: payloadData,
            recipientId: recipientId
        )
        guard !deviceOffers.isEmpty else {
            SanchrLogger.calls.error(
                "startCall: no recipient devices for \(recipientId.prefix(8))... — cannot route offer")
            throw AppError.callConnectionFailed
        }

        // Pick the device-1 entry (or the smallest device id if 1 isn't in the
        // set) for the legacy encrypted_sdp_payload field so pre-multi-device
        // servers still route the call to the recipient's primary device.
        let legacyEntry: Sanchr_Calling_DeviceCallOffer =
            deviceOffers.first(where: { $0.deviceID == 1 })
            ?? deviceOffers.min(by: { $0.deviceID < $1.deviceID })!

        // 6. Send the encrypted offer to the server.
        var callOffer = Sanchr_Calling_CallOffer()
        callOffer.recipientID = recipientId
        callOffer.callType = isVideo ? "video" : "voice"
        callOffer.deviceOffers = deviceOffers
        callOffer.encryptedSdpPayload = legacyEntry.encryptedSdpPayload

        let response = try await callService.initiateCall(callOffer)
        let callId = response.callID
```

- [ ] **Step 2: Remove the stale FIXME comment**

The comment block at lines 208-214 (about hard-coded device 1 PreKey semantics) can be trimmed to:

```swift
        // Call offers always force a fresh PreKeySignalMessage per device —
        // encryptCallOffers resets each per-device session before encrypt so
        // an out-of-sync session on either side self-heals on the next call.
```

- [ ] **Step 3: Run the fan-out test**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests/test_startCall_fansOutOfferToAllRecipientDevices \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -15
```

Expected: PASS.

- [ ] **Step 4: Run the full `CallManagerE2EETests` to confirm no regressions**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -40
```

Expected: every test PASS. If `test_startCall_encryptsAndSendsPayload` fails because the mock's `encryptCallOffers` returns `[]` (default stub from Task D1 step 3), update that one mock to return a non-empty list:

```swift
// In MockSignalManager (CallManagerE2EETests.swift top)
func encryptCallOffers(plaintext: Data, recipientId: String) async throws
    -> [Sanchr_Calling_DeviceCallOffer] {
    var entry = Sanchr_Calling_DeviceCallOffer()
    entry.deviceID = 1
    entry.encryptedSdpPayload = plaintext
    return [entry]
}
```

- [ ] **Step 5: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Platform/Calls/CallManager.swift \
        Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift
git commit -m "fix(calls): fan out outgoing call offer to every recipient device

startCall now calls signalManager.encryptCallOffers and ships the result as
CallOffer.device_offers. The legacy encrypted_sdp_payload mirrors the
device-1 (or lowest-device-id) ciphertext so pre-multi-device servers still
route the call to the recipient's primary device. Eliminates the deviceId:1
literals at the outgoing-encrypt site."
```

---

## Sub-phase E — In-call signaling: `answerer_device`

Goal: callee broadcasts its own device id on the CallJoin so the caller can decrypt answers; callee encrypts the answer for the caller device it already recovered in Sub-phase C.

### Task E1: Inject `localDeviceId` resolver into `CallManager`

**Files:**
- Modify: `Platform/Calls/CallManager.swift` (init + stored property)
- Modify: `App/DependencyContainer.swift` (wire `SessionService.currentDeviceId`)

- [ ] **Step 1: Write the failing test**

Append to `CallManagerE2EETests.swift`:

```swift
    /// sendEncryptedSessionDescription must encrypt for the caller's actual
    /// device (recovered during offer decrypt), not device 1.
    func test_sendEncryptedSessionDescription_usesRemoteCallerDeviceForEncrypt() async throws {
        final class TargetRecordingSignalManager: SignalProtocolManagerProtocol, @unchecked Sendable {
            let localUserId: String = "test-local-user"
            var lastEncryptDeviceId: Int32 = -1
            func encrypt(plaintext: Data, for userId: String, deviceId: Int32) async throws -> Data {
                lastEncryptDeviceId = deviceId
                return plaintext
            }
            func decrypt(ciphertext: Data, from senderId: String, senderDevice: Int32) async throws -> Data { ciphertext }
            func establishSession(with userId: String, deviceId: Int32) async throws {}
            func hasSession(with userId: String, deviceId: Int32) throws -> Bool { true }
            func hasSession(with userId: String) -> Bool { true }
            func encryptForAllDevices(plaintext: Data, recipientId: String) async throws -> [Sanchr_Messaging_DeviceMessage] { [] }
            func encryptCallOffers(plaintext: Data, recipientId: String) async throws -> [Sanchr_Calling_DeviceCallOffer] { [] }
            func decryptEnvelope(_ envelope: Sanchr_Messaging_EncryptedEnvelope) async throws -> Data { envelope.ciphertext }
            func decryptSealedEnvelope(_ ciphertext: Data) async throws -> SealedDecryptResult {
                throw AppError.decryptionFailed(reason: "not used")
            }
            func resetSession(with userId: String, deviceId: Int32) throws {}
            func safetyNumber(for userId: String, deviceId: Int32) throws -> String { "" }
            func scannableFingerprint(for userId: String, deviceId: Int32) throws -> Data { Data() }
            func compareFingerprint(_ scannedData: Data, for userId: String, deviceId: Int32) throws -> Bool { true }
            func markIdentityVerified(userId: String) {}
            func isIdentityVerified(userId: String) -> Bool { false }
            func localIdentityKeyData() throws -> Data { Data() }
            func remoteIdentityKeyData(for userId: String, deviceId: Int32) throws -> Data { Data() }
        }

        let signalManager = TargetRecordingSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager
        )

        // Drive a valid decrypt so remoteCallerDevice is set to 9.
        let payload = try makeSealedPayload(
            payloadFingerprint: "sha-256 DE:AD:BE:EF",
            sdpBody: "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n"
        )
        var offerEvent = makeOfferEvent(payload: payload, callerId: "alice")
        offerEvent.callerDevice = 9
        _ = await callManager.handleIncomingCallOffer(offerEvent)
        XCTAssertEqual(callManager.remoteCallerDevice, 9)

        // Invoke the private-ish path via the test-only hook added below.
        let answerDesc = RTCSessionDescription(type: .answer, sdp: "v=0\r\na=fingerprint:sha-256 DE:AD:BE:EF\r\n")
        callManager.peerId = "alice"
        try await callManager.testOnly_sendEncryptedSessionDescription(answerDesc, type: "answer", callId: "test-call-id")

        XCTAssertEqual(signalManager.lastEncryptDeviceId, 9,
            "answer ciphertext must be addressed to the caller's recovered device, not device 1")
    }
```

Add a `testOnly_` forwarding method in `CallManager.swift` near the bottom of the primary class body (before the `CXProviderDelegate` extension at line 1676):

```swift
#if DEBUG
    /// Test-only shim so unit tests can exercise the encrypt-answer path
    /// without standing up a full WebRTC/CallKit pipeline. Do not call from
    /// production code — use the real signaling flow instead.
    func testOnly_sendEncryptedSessionDescription(
        _ description: RTCSessionDescription,
        type: String,
        callId: String
    ) async throws {
        try await sendEncryptedSessionDescription(description, type: type, callId: callId)
    }
#endif
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests/test_sendEncryptedSessionDescription_usesRemoteCallerDeviceForEncrypt \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -15
```

Expected: FAIL — `lastEncryptDeviceId == 1`, not `9`.

- [ ] **Step 3: Replace the hardcoded `deviceId: 1` in `sendEncryptedSessionDescription`**

In `CallManager.swift:871-901`, replace the encrypt call (line 891-895):

```swift
        // Encrypt the answer for the exact caller device we recovered during
        // offer decrypt. Falls back to device 1 when we never received a
        // caller_device (legacy offer path).
        let targetDevice: Int32 = remoteCallerDevice > 0 ? remoteCallerDevice : 1
        let encryptedPayload = try await signalManager.encrypt(
            plaintext: payloadData,
            for: recipientId,
            deviceId: targetDevice
        )
```

Delete the `// FIXME: senderDevice hard-coded to 1` comment on the line above.

- [ ] **Step 4: Emit `answererDevice` on every `CallJoin` + set `peerDevice` on outbound `CallSignal`s**

In `openSignalingStream` (~line 924), find where the join signal is constructed. If the current code yields a bare `CallJoin`, update it to stamp the local device id. Inside `CallManager`, add a dependency:

```swift
// Add to "// MARK: - Dependencies" block (after peerProfileResolver declaration):
private let localDeviceIdProvider: @Sendable () -> Int32
```

Update `init(...)`:

```swift
    init(
        webRTCClient: WebRTCClient,
        callService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol,
        signalManager: SignalProtocolManagerProtocol,
        tokenRefresher: @escaping @Sendable () async throws -> Void = {},
        peerProfileResolver: @escaping @Sendable (String) async -> CallPeerProfile? = { _ in nil },
        localDeviceIdProvider: @escaping @Sendable () -> Int32 = { 1 }
    ) {
        self.webRTCClient = webRTCClient
        self.callService = callService
        self.signalManager = signalManager
        self.tokenRefresher = tokenRefresher
        self.peerProfileResolver = peerProfileResolver
        self.localDeviceIdProvider = localDeviceIdProvider
        // ... remainder unchanged
    }
```

Find the CallJoin construction site inside `openSignalingStream` (search the file for `CallJoin()`). Replace:

```swift
var join = Sanchr_Calling_CallJoin()
join.role = role
join.answererDevice = localDeviceIdProvider()
var joinSignal = Sanchr_Calling_CallSignal()
joinSignal.callID = callId
joinSignal.join = join
joinSignal.peerDevice = localDeviceIdProvider()
outboundContinuation?.yield(joinSignal)
```

Also stamp `peer_device` on every outbound `CallSignal`. In `sendEncryptedSessionDescription` (line 897-900), after constructing the signal:

```swift
        var signal = Sanchr_Calling_CallSignal()
        signal.callID = callId
        signal.encryptedSdpAnswer = encryptedPayload
        signal.peerDevice = localDeviceIdProvider()
        outboundContinuation?.yield(signal)
```

And in `sendOrBufferLocalIceCandidate` (~line 1611), similarly stamp `peer_device` on the `CallSignal` built there.

- [ ] **Step 5: Wire the provider in `DependencyContainer.swift`**

Find the `CallManager(` construction in `App/DependencyContainer.swift` (search for `CallManager(`). Pass:

```swift
localDeviceIdProvider: { [weak sessionService] in
    Int32(sessionService?.currentDeviceId ?? "") ?? 1
}
```

(Match the existing capture style used elsewhere in the container.) Per CLAUDE.md rule 6, re-read the file first to confirm the existing pattern for `sessionService` captures.

- [ ] **Step 6: Also decrypt incoming `encrypted_sdp_answer` using `peerDevice`**

Find the inbound signaling handler at `handleSignalingStream` (line ~970). Locate the branch that decodes `encrypted_sdp_answer` (search `encryptedSdpAnswer`). Replace the hardcoded decrypt:

```swift
                case .encryptedSdpAnswer(let cipher):
                    let peerDevice: Int32 = incoming.peerDevice > 0 ? incoming.peerDevice : 1
                    let plaintext: Data
                    do {
                        plaintext = try await signalManager.decrypt(
                            ciphertext: cipher,
                            from: peerId ?? "",
                            senderDevice: peerDevice
                        )
                    } catch {
                        SanchrLogger.calls.error(
                            "stream: decrypt answer failed from peer_device=\(peerDevice): \(error)")
                        continue
                    }
                    // ...existing SealedCallPayload decode + setRemoteDescription path
```

Read the existing surrounding code and adapt — do not blind-replace. The exact variable name for the loop element (`incoming`, `signal`, `event`, etc.) varies; read the file.

- [ ] **Step 7: Run the test and the full suite**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -40
```

Expected: all tests PASS, including the new E1 test.

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Platform/Calls/CallManager.swift \
        App/DependencyContainer.swift \
        Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift
git commit -m "fix(calls): address in-call signaling to the actual peer device

CallManager now carries a localDeviceIdProvider (resolved from
SessionService.currentDeviceId at wire-up time) and stamps answerer_device on
CallJoin plus peer_device on every outbound CallSignal. On the callee side,
encrypted_sdp_answer is encrypted for the caller's recovered remoteCallerDevice
instead of hardcoded 1. On the caller side, encrypted_sdp_answer is decrypted
against the server-populated peer_device, again falling back to 1 when the
server hasn't rolled the new field yet."
```

---

## Sub-phase F — Video flag enforcement

Goal: `AppConfiguration.isVideoCallEnabled` becomes a real gate instead of inert config.

### Task F1: Inject the flag into `CallManager` and gate `startCall` + `requestVideoUpgrade`

**Files:**
- Modify: `Platform/Calls/CallManager.swift`
- Modify: `App/DependencyContainer.swift`

- [ ] **Step 1: Write failing tests**

Append to `CallManagerE2EETests.swift`:

```swift
    /// With isVideoCallEnabled=false, requesting a video call must fail before
    /// any network or WebRTC side effects occur.
    func test_startCall_rejectsVideoWhenFeatureDisabled() async {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager,
            isVideoCallEnabled: false
        )

        do {
            try await callManager.startCall(recipientId: "bob", recipientName: "Bob", isVideo: true)
            XCTFail("Expected startCall to throw when isVideoCallEnabled is false")
        } catch AppError.featureDisabled {
            // expected
        } catch {
            XCTFail("Expected AppError.featureDisabled, got \(error)")
        }
        if case .idle = callManager.callState {
            // no side effects — expected
        } else {
            XCTFail("callState must remain .idle when the gate blocks startCall")
        }
    }

    /// With isVideoCallEnabled=true, voice + video calls work unchanged.
    func test_startCall_allowsVoiceWhenVideoDisabled() async throws {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager,
            isVideoCallEnabled: false
        )

        do {
            try await callManager.startCall(recipientId: "bob", recipientName: "Bob", isVideo: false)
        } catch {
            throw XCTSkip("WebRTC/CallKit unavailable: \(error.localizedDescription)")
        }
        if case .outgoing = callManager.callState {
            // expected — voice is unaffected by the video gate
        } else {
            XCTFail("Voice startCall must succeed regardless of video gate; got \(callManager.callState)")
        }
    }

    /// requestVideoUpgrade on an audio call is a no-op when the flag is off.
    func test_requestVideoUpgrade_noopWhenFeatureDisabled() async {
        let signalManager = MockSignalManager()
        let callService = MockCallSignalingService()
        let webRTCClient = WebRTCClient()
        let callManager = CallManager(
            webRTCClient: webRTCClient,
            callService: callService,
            signalManager: signalManager,
            isVideoCallEnabled: false
        )
        callManager.callState = .active(callId: "cid", startTime: Date())

        callManager.requestVideoUpgrade()

        XCTAssertFalse(callManager.outgoingVideoUpgradePending,
            "requestVideoUpgrade must be a no-op when the feature is disabled")
    }
```

- [ ] **Step 2: Verify they fail**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests/test_startCall_rejectsVideoWhenFeatureDisabled \
  -only-testing:SanchrTests/CallManagerE2EETests/test_requestVideoUpgrade_noopWhenFeatureDisabled \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -20
```

Expected: compile error — `CallManager.init` doesn't take `isVideoCallEnabled:`.

- [ ] **Step 3: Add the init parameter + stored property**

In `CallManager.swift`, add to the Dependencies block:

```swift
    private let isVideoCallEnabled: Bool
```

Update `init` (line 136-142) to accept `isVideoCallEnabled: Bool = true` (default stays `true` so existing tests that don't opt in to the gate keep passing). Assign it in the body.

- [ ] **Step 4: Add the `AppError.featureDisabled` case**

Search for the `AppError` enum (likely under `SanchrShared/Errors/` or similar):

```bash
grep -rn 'enum AppError' . --include='*.swift' | head -5
```

In that enum, add `case featureDisabled(feature: String)`. In its `localizedDescription` extension (if present), map it to `"Feature is not available in this build"`.

- [ ] **Step 5: Gate `startCall`**

In `CallManager.swift:174`, at the top of `startCall`, right after the `.idle` guard:

```swift
    func startCall(recipientId: String, recipientName: String, isVideo: Bool) async throws {
        guard case .idle = callState else {
            throw AppError.callAlreadyInProgress
        }
        if isVideo && !isVideoCallEnabled {
            SanchrLogger.calls.warning("startCall: video requested but feature is disabled — blocking")
            throw AppError.featureDisabled(feature: "video_call")
        }
        // ...existing body
```

- [ ] **Step 6: Gate `requestVideoUpgrade`**

In `CallManager.swift:777-793`:

```swift
    func requestVideoUpgrade() {
        guard isVideoCallEnabled else {
            SanchrLogger.calls.warning("requestVideoUpgrade: feature disabled — ignoring")
            return
        }
        // ...existing body
```

- [ ] **Step 7: Pass the flag from `DependencyContainer`**

In `App/DependencyContainer.swift`, find the `CallManager(` init site. Pass:

```swift
isVideoCallEnabled: AppConfiguration.current.isVideoCallEnabled
```

Re-read the file first (CLAUDE.md rule 6 — the container is long and has had drift). Verify the `AppConfiguration.current` import is present (it should already be, since the container uses other config fields).

- [ ] **Step 8: Update the `isVideoCallEnabled` comment in `AppConfiguration.swift`**

Remove the `FIXME(calls/P0-F)` block from Task A2 (now resolved) and replace with:

```swift
/// When `false`, `CallManager` refuses to start a video call and ignores
/// requestVideoUpgrade. The video UI in CallsListView + the chat video CTA
/// are hidden when the flag is off. This is the single gate — do not add
/// duplicate checks in higher layers.
public let isVideoCallEnabled: Bool
```

- [ ] **Step 9: Run tests + full build**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -40
```

Expected: all tests pass, including the three new F tests.

- [ ] **Step 10: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Platform/Calls/CallManager.swift \
        App/DependencyContainer.swift \
        SanchrShared/Config/AppConfiguration.swift \
        Tests/UnitTests/Platform/Calls/CallManagerE2EETests.swift
# If AppError lives in its own file, add it too.
git commit -m "feat(calls): enforce AppConfiguration.isVideoCallEnabled

Gates startCall(isVideo=true) and requestVideoUpgrade at the CallManager
layer — throws AppError.featureDisabled for the former, no-ops the latter.
Voice calls and answering an incoming video call (for compat) are unaffected.
Wires the flag through DependencyContainer from AppConfiguration.current.
Docs the single-gate rule on the field declaration."
```

---

### Task F2: Hide the video CTA in UI when the feature is off

**Files:**
- Modify: `Features/Calls/Presentation/CallsListView.swift` (or whichever view hosts the "Start video call" action — find it via grep)

- [ ] **Step 1: Find the call-start CTA**

```bash
grep -rn 'startCall\|isVideo: true' Features --include='*.swift' | head -10
```

Likely hits: `CallsListView.swift`, and a chat-header view in `Features/Chats/`.

- [ ] **Step 2: Inject the flag at each CTA call site**

For each view that offers a "start video call" button, wrap the button construction in:

```swift
if AppConfiguration.current.isVideoCallEnabled {
    // existing video button
}
```

If the view takes `AppConfiguration` via environment or init, prefer that over `.current` so previews + tests can override.

- [ ] **Step 3: Manual verification**

This is UI — there is no automated assertion for "the button is hidden". Note in the commit message that visual verification was done with:

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

And then launching the app manually. Per `CLAUDE.md` (the iOS Swift + Xcode analogue of rule 8 — "if you can't test the UI, say so explicitly rather than claiming success"), be honest in the commit body: "verified visually in simulator — no UI test coverage for this gate yet."

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add Features/
git commit -m "feat(ui): hide video CTAs when isVideoCallEnabled is false

Gates the 'Start video call' button in calls list + chat header on
AppConfiguration.current.isVideoCallEnabled. Verified visually in the iPhone
17 Pro simulator. No automated UI-test coverage for the gate yet — UI
launch-hook coverage is a P5 hygiene task."
```

---

## Sub-phase G — Phase wrap-up

- [ ] **Step 1: Re-run the complete unit suite**

```bash
xcodebuild -workspace Sanchr.xcworkspace -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test 2>&1 | tail -80
```

Expected: every test passes. If any of the 7 pre-existing App-Group-related failures (`MessageRepositorySealedSendTests`, `P2PPresenceTests`) are still red, they are **unrelated** to this phase — they belong to P2 (Data integrity). Note them in the phase retrospective but don't block on them.

- [ ] **Step 2: Grep confirms the hardcoded-device-1 literals are gone from call paths**

```bash
grep -n 'deviceId: 1\|senderDevice: 1' \
  Platform/Calls/CallManager.swift
```

Expected: zero matches inside `CallManager.swift`. (Hits in other files are out of scope for this phase.)

- [ ] **Step 3: Append the retrospective to the master roadmap**

Edit `docs/superpowers/plans/2026-04-24-ios-production-readiness.md`, in the **Status log** table at the bottom, add:

```
| 2026-MM-DD | P0 Calls | Landed. Multi-device decrypt + fan-out encrypt + answerer_device + video flag wired. Server-side coordination required for full end-to-end multi-device (see calls-hardening plan appendix). |
```

- [ ] **Step 4: Hand off to P1 planning**

Kick off the next planning pass with:

> "Calls hardening is merged. Start P1 release-blockers plan: privacy manifest, export compliance, env/scheme hardening, cert pinning wiring or removal."

---

## Server-side coordination checklist (for the backend team)

Track these as issues in the backend tracker, not in this iOS plan:

1. **`CallOfferEvent.caller_device`** — populate from the `sender_device` of the sealed envelope that carried the offer. Today the server sets it to zero (field didn't exist).
2. **`CallOffer.device_offers`** — read the repeated list and route each entry to the matching recipient device's inbox. Fall back to `encrypted_sdp_payload` + device 1 when the list is empty (current behavior).
3. **`CallJoin.answerer_device` → `CallSignal.peer_device`** — server captures the value from the callee's Join and mirrors it on every signal relayed to the caller. Client fills it in both directions (caller also sets it on outbound signals); server should preserve it unchanged.
4. **VoIP push `caller_device` field** — server emits the APNs payload and must include `"caller_device": <N>` so `PushManager` forwards it to CallManager.
5. **TURN server rollout** — the `turnServers` list was removed from iOS. Confirm `CallSignalingService.GetTurnCredentials` issues time-scoped credentials. Secrets stay server-side. Out-of-scope for iOS.

Until all five are shipped, iOS behavior is a strict superset of today (falls back to device 1 everywhere), so multi-device users are no worse off during the rollout window.
