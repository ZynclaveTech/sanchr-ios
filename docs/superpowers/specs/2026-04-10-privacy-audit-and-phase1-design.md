# Privacy Audit & Phase 1 Hardening Design

**Date:** 2026-04-10
**Status:** Design approved, ready for implementation planning
**Scope gate:** Phase 1 only (iOS client). P2/P3/P4 documented but deferred.

## Context

Two inputs drove this audit:

1. User report that the Privacy settings screen has extra borders on the cards and does not adapt to dark theme.
2. A request to verify the Sanchr Mode and related privacy features against the threat model in the research paper at `web/public/research.pdf` (Pandey, "Threat-Driven Extensions to the Signal Protocol", v0.0.1, 2026-04-08).

The paper claims three defenses unified by one invariant:

- **D1:** OPRF-PSI contact discovery on Ristretto255 with a daily-rotated Bloom filter, bounding discovery exposure to 24 hours.
- **D2:** Ratchet-derived media keys via a parallel HKDF chain, plus device-local `AccessK` with a 30-day TTL for re-access.
- **D3:** Ephemeral Key Framework — uniform TTL lifecycle management for auxiliary state (discovery/media/presence/prekey classes).
- **Invariant (Definition 1):** no cryptographic material is both cross-domain and long-lived.

The Privacy screen is the user-visible surface for the D2/D3-adjacent toggles (Sanchr Mode, read receipts, typing indicator, online status, profile photo visibility) plus Secret Vault entry, blocked contacts, and app lock. This spec audits whether the client and backend actually honour those claims, then hardens the iOS side in Phase 1.

## Goals

- **G1 — Honest UI.** Every control on the Privacy screen must either do what it says or not exist. No `@State` theatre.
- **G2 — Chokepoint enforcement.** Sanchr Mode gates live in one place (`MessageRepository`), not at every call site. A new code path cannot bypass the gate by forgetting a check.
- **G3 — Clean logout.** No user's privacy state bleeds into another user's session on the same device.
- **G4 — Theme fidelity.** The Privacy screen renders correctly in dark mode without the extra card borders the user flagged.
- **G5 — Testable enforcement.** Tests prove that calling a gated repo method does not hit gRPC. Getter-only tests are insufficient.
- **G6 — Document the rest.** Phases 2–4 (backend enforcement, paper alignment, metadata privacy) are captured here so they are not lost, even though implementation is deferred.

## Non-Goals

- Any backend change (Rust, proto, migrations). Out of Phase 1.
- Any paper revision. Out of Phase 1.
- Any change to Signal protocol crypto — out of scope per paper §2.6.
- Metadata privacy work (Sealed Sender, P2P presence, opaque conversation IDs). Tracked in `metadata_privacy_plan.md` memory; out of Phase 1.
- New features (e.g., actually implementing Disappearing Messages). We are removing the dead controls, not building them.

---

## Audit Findings

### A. What Works

Validated by code reads against paper claims:

| Claim (paper §) | Code location | Status |
|---|---|---|
| D1: OPRF-PSI on Ristretto255 | `backend/crates/vync-psi/src/oprf.rs` | ✓ Implemented |
| D1: Bloom filter negative layer | `backend/crates/vync-psi/src/bloom.rs` | ✓ Implemented |
| D1: Daily salt rotation via EKF | `backend/crates/vync-core/src/discovery/salt_rotation.rs` (24 h loop) | ✓ Implemented |
| D2: `MediaKn = HKDF(CKn, file_hash, "sanchr-media-v1")` | `backend/crates/vync-server-crypto/src/media_keys.rs:22-32` | ✓ Implemented |
| D2: Client-side `AccessK` derivation + 30-day TTL | Recent iOS vault rewrite (`ios/Sanchr-iOS/SanchrShared/Crypto/`, `Shared/Services/AccessKeyStore.swift`) | ✓ Implemented |
| D3: EKF key classes with correct TTLs | `backend/crates/vync-core/src/ekf/models.rs:16-58` (discovery 24 h, media 30 d, presence 5 min, prekey 7 d) | ✓ Implemented |
| D3: Null-sentinel overwrite for presence | `backend/crates/vync-core/src/ekf/manager.rs:190-215` | ✓ Implemented |
| D3: `lifecycle_tick` scan + policy apply | `backend/crates/vync-core/src/ekf/manager.rs:42-221` | ✓ Implemented |
| iOS `PrivacySettingsCache` gates 3 signals on Sanchr Mode | `ios/Sanchr-iOS/Shared/Services/PrivacySettingsCache.swift:14-30` | ✓ Implemented (getter only) |
| iOS settings sync to backend | `ios/Sanchr-iOS/Features/Settings/Presentation/SettingsViewModel.swift:109-197` | ✓ Implemented for `readReceipts`, `typingIndicator`, `onlineStatusVisible`, `profilePhotoVisibility`, `vyncModeEnabled` |
| iOS enforcement wired at view layer | `Features/Chats/Presentation/ChatDetailView.swift:384, 421, 476, 486, 1221`, `Shared/Services/RealtimeService.swift:187, 203, 364` | ✓ Correctly gated — but fragile (see bug B-2) |

The crypto layers are in good shape. The bugs are in enforcement hygiene, lifecycle hygiene, and UI honesty.

### B. Critical Bugs — iOS Client

**B-1 — `PrivacySettingsCache` never cleared on logout.** `SessionService.clearSessionState()` (`Shared/Services/SessionService.swift:242-252`) resets the auth fields but leaves `container.privacySettings` holding the previous user's flags. The cache is a long-lived singleton in `DependencyContainer.swift:291` and survives logout. If user A had `readReceipts = false, sanchrModeEnabled = true` and logs out, user B logs in, and the app opens a chat before `loadSettings()` completes the network round-trip, user B's outbound receipts are silently suppressed. **Severity: HIGH.**

**B-2 — Sanchr Mode gates live at call sites, not at the chokepoint.** Enforcement is scattered across:

- `Shared/Services/RealtimeService.swift:187, 203, 364` — presence heartbeat gate.
- `Features/Chats/Presentation/ChatDetailView.swift:384, 421, 476, 486, 1221` — typing and read-receipt gates.
- `Features/Chats/Presentation/ChatDetailViewModel.swift:841-907` — typing indicator methods take a `canSend: Bool` parameter.

The actual repository methods (`MessageRepository.markAsRead`, `sendTypingIndicator`, `sendPresenceHeartbeat` at `Shared/Repositories/MessageRepository.swift:296, 492, 505`) do not consult the cache. Any new call site that forgets the `canSend:` parameter, or any new surface that bypasses `ChatDetailView` (notification quick-reply, vault reshare, future share extension, shortcut action, message forward), sends these signals unconditionally. Sanchr Mode "works" only because every current call site remembered to check. That is not enforcement; it is discipline-by-convention. **Severity: HIGH (architectural).**

**B-3 — Last Seen, About, Disappearing Messages are dead UI.** `Features/Settings/Presentation/PrivacyView.swift:10-12` declares three `@State` vars backed by no proto field, no `debouncedSync()` call, no persistence. Users toggle them believing they do something; they reset to hardcoded defaults on every screen open. The `lastSeenVisibility` hydration at line 45 even fakes correlation with `onlineStatusVisible` ("contacts" vs "nobody"), which is misleading because the real control is the Online Status row further down the screen. **Severity: HIGH (deceptive UI).**

**B-4 — `PrivacySettingsCache` tracks only 4 fields.** Missing `profilePhotoVisibility` and `blockList`. The cache cannot answer "may I display user X's avatar?" or "is user Y blocked?" without a round-trip. Every client-side privacy decision that should consult the cache currently either does a network call or skips the check entirely. **Severity: MEDIUM.**

### C. Critical Bugs — Rust Backend (Phase 2, documented here)

**C-1 — Blocked contacts not enforced server-side.** `is_blocked` is stored in the `contacts` table (`backend/crates/vync-db/src/postgres/contacts.rs:109-128`) but never checked in messaging/typing/presence inbound handlers. A sender bypassing the client (direct gRPC) can still deliver to a blocked user. Block is client-filter only. **Severity: HIGH.**

**C-2 — Profile photo visibility not enforced server-side.** `profile_photo_visibility` persists in settings (`backend/crates/vync-core/src/settings/handlers.rs:62-96`) but the `avatar_url` is returned unconditionally in profile lookups. A curious user can fetch any avatar regardless of its visibility setting. **Severity: HIGH.**

**C-3 — No rate limit on OPRF discovery endpoint.** `/oprf_discover` has auth check only (`backend/crates/vync-core/src/discovery/service.rs:24-35`). Unlike `/sync_contacts` which is capped at 10/hour, OPRF is unlimited. An attacker can do unbounded oracle queries against the server secret. Paper §3.2 implies the OPRF protects the server secret under DDH; that claim weakens if the attacker can run ~10⁶ queries/day. **Severity: HIGH.**

**C-4 — No batch-size cap on OPRF request.** Clients can send arbitrarily large `blinded_points` vectors. DoS vector against the per-query scalar multiplication cost. **Severity: MEDIUM.**

### D. Paper-vs-Code Discrepancies (Phase 3, documented here)

**D-1 — OPRF server secret never rotates.** Paper §9.1 L3 claims "weekly rotation and HSM storage". `backend/crates/vync-core/src/main.rs:123-157` loads the secret once at startup from an env var and never rotates it. The weekly bound from the paper becomes the deployment lifetime in practice. **Severity: MEDIUM (policy bound violated).**

**D-2 — Media ciphertexts never expire.** Paper §4.3.1 + Table 5 (media class, 30 d, Delete policy) bounds AccessK TTL to 30 days. AccessK deletion after 30 days means the key is gone — but the ciphertext in S3 / `media_objects` in Postgres remains forever because there is no S3 lifecycle rule or database row deletion aligned with the AccessK expiry. Decision needed: either add an S3 lifecycle policy that ages out ciphertext 30 days after upload, or document in the paper that server storage of ciphertext is intentionally unbounded and the 30-day AccessK window is the user's re-access window, not a retention policy. **Severity: MEDIUM.**

**D-3 — PreKey "Replenish" policy is implicit, not explicit.** Paper §5.2.2 lists Replenish as one of the four expiration policies. `backend/crates/vync-core/src/ekf/models.rs:65-76` exposes only `Rotate / Delete / Overwrite`. PreKey replenishment happens via a Redis counter plus client-triggered top-up, which is functionally equivalent but does not match the paper's enum. Either add an explicit `ExpPolicy::Replenish` variant or revise the paper to say "PreKey TTL = 7 d, Delete-on-expire, client replenishes on detection". **Severity: LOW (semantic).**

**D-4 — ScyllaDB compaction timing not documented.** Paper Claim 7 warns LSM-tree engines may retain pre-compaction state longer than the policy window. The `auxiliary_state` keyspace lives in ScyllaDB. There is no `gc_grace_seconds` or compaction-strategy config visible for this keyspace. A deleted EKF entry may remain physically recoverable from SSTables for longer than the EKF TTL claims. **Severity: MEDIUM.**

**D-5 — LOC counts in paper do not match code.** Paper Table 10: `vync-psi ~ 2,200 LOC`, actual ≈ 995. `ekf ~ 1,800 LOC`, actual ≈ 379. `server-crypto + media ~ 1,400 LOC`, actual ≈ 821. These are likely overcounts in the paper (tests, comments, generated protobuf) rather than missing code. **Severity: LOW (paper accuracy).**

**D-6 — Deployment architecture mismatch.** Paper §7.1 claims "managed Kubernetes cluster, 3 nodes, gRPC microservices". Code is a monolithic `main.rs` binary (`vync-core`) composed of modules, not separate services. **Severity: LOW (paper accuracy).**

### E. UX Issues — iOS Privacy Screen

**E-1 — Extra borders on cards.** Four `.overlay { RoundedRectangle(cornerRadius:).stroke(Color(hex: 0xE5E7EB), lineWidth: 1) }` blocks sit on top of filled cards in `Features/Settings/Presentation/PrivacyView.swift`:

- Line 166-168 (read receipts row).
- Line 259-261 (privacy controls section).
- Line 335-337 (generic `cardRow` helper — affects every row built through it: Last Seen, Profile Photo, About, App Lock, Secret Vault, Disappearing Messages, Blocked Contacts).
- Line 475-477 (blocked contact row in `BlockedContactsView`).

User explicitly flagged these for removal.

**E-2 — Dark theme broken.** Hardcoded light-palette hex values throughout `PrivacyView.swift`:

- `Color(hex: 0xEEF2FF)` — icon tile background (Last Seen, App Lock).
- `Color(hex: 0xECFEFF)` — icon tile background (Profile Photo, Secret Vault).
- `Color(hex: 0xF3E8FF)` — icon tile background (About, Typing Indicators).
- `Color(hex: 0xDCFCE7)` — icon tile background (Read Receipts, Online Status).
- `Color(hex: 0xFFEDD5)` — icon tile background (Disappearing Messages).
- `Color(hex: 0xFEE2E2)` — icon tile background (Blocked Contacts), circle fill (`BlockedContactsView`).
- `Color(hex: 0xF3F4F6)` — empty-state circle (`BlockedContactsView`).
- `Color(hex: 0xE5E7EB)` — border stroke (see E-1).

In dark mode these stay light, so icon tiles and borders render as bright patches on the dark screen. The existing `SanchrExportColors.*` token set adapts correctly.

---

## Decomposition

This audit exceeds a single implementation sprint. Split into four phases, with Phase 1 implementation-ready and Phases 2–4 documented but deferred to their own specs/plans.

### Phase 1 — iOS Privacy UX + Client Enforcement Hardening *(this spec)*

Addresses bugs B-1 through B-4 and UX issues E-1, E-2. Pure iOS work. One sprint.

### Phase 2 — Backend Privacy Enforcement Hardening *(deferred)*

Addresses C-1 through C-4:

- Server-side blocked contacts enforcement on inbound messaging / typing / presence (drop, not filter).
- Server-side profile photo visibility enforcement on avatar fetch.
- Server-side read receipt suppression when recipient has `read_receipts = false` (currently client honor system for the pair).
- Server-side typing indicator suppression verification (`backend/crates/vync-core/src/presence/handlers.rs:146-157` currently checks — verify coverage).
- OPRF rate limit (per-user + per-IP, aligned with `/sync_contacts` limit).
- OPRF batch-size cap (recommend ≤ 500 blinded points per request to match paper §3.2.3 "batch processing: vectorized scalar multiplication for 500+ contacts").
- Cross-device block list sync (currently a single Postgres row per pair with no multi-device propagation).

**Owner when scheduled:** backend crate work, follow-up spec under `backend/docs/superpowers/specs/`.

### Phase 3 — Paper-Credibility Alignment *(deferred)*

Addresses D-1 through D-6:

- OPRF server secret weekly rotation (epoch-keyed store, dual-key overlap window, client unaware because OPRF is stateless per request).
- Media ciphertext lifecycle decision + implementation: either S3 lifecycle rule aligned to 30-day AccessK TTL, or paper revision clarifying unbounded server-side ciphertext retention.
- PreKey Replenish policy: either add `ExpPolicy::Replenish` variant to `ekf::ExpPolicy` or paper revision.
- ScyllaDB `gc_grace_seconds` + compaction strategy config for `auxiliary_state` keyspace; document the chosen values + rationale.
- Paper revision pass: LOC counts updated; deployment architecture described accurately.

**Owner when scheduled:** backend + research paper. Follow-up spec.

### Phase 4 — Metadata Privacy *(deferred)*

Already scoped in a separate memory (`metadata_privacy_plan.md`): Sealed Sender → encrypted profile → P2P presence → opaque conversation IDs → sealed receipts + random batching → push token rotation. Six phases, 10–12 days of work. Not overlapping with this audit.

**Owner when scheduled:** separate cross-cutting sprint.

---

## Phase 1 Design

### 1. Architecture

**1.1 — Extend `PrivacySettingsCache`.** Current fields at `Shared/Services/PrivacySettingsCache.swift:9-12`:

```
_readReceipts: Bool = true
_typingIndicator: Bool = true
_onlineStatusVisible: Bool = true
_sanchrModeEnabled: Bool = false
```

Add:

```
_profilePhotoVisibility: String = "everyone"
_blockedUserIds: Set<String> = []
```

Add matching getters under the existing `NSLock`:

```
var profilePhotoVisibility: String { lock.lock(); defer { lock.unlock() }; return _profilePhotoVisibility }
var blockedUserIds: Set<String> { lock.lock(); defer { lock.unlock() }; return _blockedUserIds }
func isBlocked(_ userId: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _blockedUserIds.contains(userId) }
```

Add `clear()` (resets everything to defaults under the lock) and `update(blockList:)` (sets the blocked set — to be called from wherever the blocked list is fetched).

Extend the existing `update(from: Vync_Settings_UserSettings)` to also assign `_profilePhotoVisibility = settings.profilePhotoVisibility`.

**1.2 — Gate relocation into `MessageRepositoryImpl` via a testable gate struct.**

Two layers work together: a new `MessagingPrivacyGate` struct that owns the decision logic, and the repository that consults it.

**Why a gate struct instead of inline `guard` checks:** `MessageRepositoryImpl` has six dependencies — `GRPCClientProtocol`, `LocalDatabaseProtocol`, `SignalProtocolManagerProtocol`, `ChatVaultPolicyMirror` (concrete final class), `VaultRepositoryProtocol`, `MediaDownloadManager` (concrete actor). Constructing it in a test would require ~100+ stub methods. Extracting the gate into a pure struct lets us unit-test the decision logic directly without touching the repository's dependency graph.

New file `Shared/Services/MessagingPrivacyGate.swift`:

```swift
struct MessagingPrivacyGate: Sendable {
    let privacySettings: PrivacySettingsCache

    enum Signal: Sendable {
        case readReceipt
        case typingIndicator
        case presenceHeartbeat
    }

    enum Decision: Sendable, Equatable {
        case allow
        case suppress
    }

    func decide(_ signal: Signal) -> Decision {
        switch signal {
        case .readReceipt:
            return privacySettings.canSendReadReceipts ? .allow : .suppress
        case .typingIndicator:
            return privacySettings.canSendTypingIndicators ? .allow : .suppress
        case .presenceHeartbeat:
            return privacySettings.canSendPresence ? .allow : .suppress
        }
    }
}
```

`Shared/Repositories/MessageRepository.swift` gains `private let privacyGate: MessagingPrivacyGate` constructed from the injected `privacySettings` at init. The three methods consult the gate:

```swift
func markAsRead(conversationId: String, upToMessageId: String) async throws {
    switch privacyGate.decide(.readReceipt) {
    case .suppress:
        try await markAsReadLocally(conversationId: conversationId, upToMessageId: upToMessageId)
        return
    case .allow:
        break
    }
    // existing body: build request, sendReceipt, markConversationAsRead
}

func sendTypingIndicator(conversationId: String, isTyping: Bool) async throws {
    guard privacyGate.decide(.typingIndicator) == .allow else { return }
    // existing body
}

func sendPresenceHeartbeat(...) async throws {
    guard privacyGate.decide(.presenceHeartbeat) == .allow else { return }
    // existing body
}
```

Gated sends are silent no-ops (not errors). A disabled read receipt is expected behavior. The fall-through of `markAsRead` → `markAsReadLocally` preserves the user experience: their unread counter still clears; the sender simply does not see a read indicator. The repo holds the gate struct as a stored property to ensure all three methods use the same cache reference and so tests can inject a custom gate if needed via a future test-only init overload.

**1.3 — Logout lifecycle.**

`SessionService` gains a `privacySettings: PrivacySettingsCache` dependency. `clearSessionState()` at `Shared/Services/SessionService.swift:242-252` calls `privacySettings.clear()` as its first action (before the `@MainActor` state resets, so that any async work triggered by state observers sees the cleared cache).

On login, existing `SettingsViewModel.loadSettings(settingsDataSource:privacySettings:)` at line 109 calls `privacySettings.update(from: settings)`, which rehydrates. The post-clear defaults (`readReceipts = true, typingIndicator = true, onlineStatusVisible = true, sanchrModeEnabled = false`) match Signal/WhatsApp's "privacy defaults to on-but-visible" convention and are safe for the brief window between session start and settings load.

**1.4 — Dependency wiring.**

`App/DependencyContainer.swift` updates:

```swift
@ObservationIgnored lazy var messageRepository: MessageRepositoryProtocol = MessageRepository(
    grpcClient: grpcClient,
    localDatabase: localDatabase,
    signalStore: signalStore,
    privacySettings: privacySettings   // new dependency
)

@ObservationIgnored lazy var sessionService: SessionService = SessionService(
    ...existing deps...,
    privacySettings: privacySettings   // new dependency
)
```

### 2. PrivacyView UX Cleanup

**2.1 — Border removal.** Delete the four `.overlay { RoundedRectangle(cornerRadius: X, style: .continuous).stroke(Color(hex: 0xE5E7EB), lineWidth: 1) }` blocks at `PrivacyView.swift:166-168, 259-261, 335-337, 475-477`. Resulting cards are pure filled surfaces via `.background(SanchrExportColors.surface).clipShape(...)`.

**2.2 — Dark theme tokens.** Replace every hardcoded hex value in `PrivacyView.swift`:

- All six pastel icon tile backgrounds (`0xEEF2FF`, `0xECFEFF`, `0xF3E8FF`, `0xDCFCE7`, `0xFFEDD5`, `0xFEE2E2`) → `SanchrExportColors.surfaceMuted`. The iconTile helper at line 374-383 already uses `.surfaceMuted` as the fill — the per-row `background:` argument is therefore redundant and should be dropped from `cardRow` and `stackedToggleRow` signatures entirely.
- The `tint:` argument for the `iconTile` (`SanchrColors.primary`, `SanchrColors.accent`, and the various role colors `0x7C3AED`, `0x16A34A`, `0xEA580C`, `0xDC2626`) should be consolidated to a single role-aware system. Keep a minimal set: `SanchrColors.primary` (neutral row), `SanchrColors.accent` (cyan/highlight), `.sanchrError` (destructive red). This reduces visual noise and matches other Settings subscreens.
- `BlockedContactsView` empty-state circle `0xF3F4F6` → `SanchrExportColors.surfaceMuted`.
- `BlockedContactsView` unblock row circle fill `0xFEE2E2` → `SanchrExportColors.surfaceMuted`.

Sanchr Mode hero card gradient (`0x111827` → `0x0F172A`) stays; it is intentionally dark in both themes.

**2.3 — Dead state removal.** Delete from `PrivacyView.swift`:

- `@State private var lastSeenVisibility = "nobody"` (line 10).
- `@State private var aboutVisibility = "everyone"` (line 11).
- `@State private var disappearingDefault = "24h"` (line 12).
- The `disappearingOptions` array (lines 19-24).
- Last Seen `Menu` block (lines 100-112) inside `accountPrivacySection`.
- About `Menu` block (lines 128-140) inside `accountPrivacySection`.
- Disappearing Messages `Menu` block (lines 205-221) inside `securityFeaturesSection`.
- `lastSeenVisibility = viewModel.onlineStatusVisible ? "contacts" : "nobody"` hydration line in `.task` (line 45).
- The `visibilityOptions` array (line 18) stays — it's still used by the Profile Photo menu.
- The `displayVisibility` helper (line 403) stays — still used.

After deletion, `accountPrivacySection` contains exactly: Profile Photo, Read Receipts.
`securityFeaturesSection` contains exactly: App Lock, Secret Vault.

**2.4 — File split.** `PrivacyView.swift` is 526 LOC pre-cleanup, roughly 350 LOC after. Per the Step 0 rule, split before restructuring:

- Extract `BlockedContactsView` (lines 418-525) into `Features/Settings/Presentation/BlockedContactsView.swift`. It is a full `View` type with its own data source and navigation destination; separating it cleanly isolates the blocked-contacts flow.
- Extract `SanchrModeCard` subview (lines 49-94) into `Features/Settings/Presentation/SanchrModeCard.swift`. Takes `vyncModeEnabled: Binding<Bool>` and an `onChange: () async -> Void` closure.

Post-split `PrivacyView.swift` targets ≤ 300 LOC.

### 3. Call-Site Migration

With gates living in the repository, every previous call site drops its manual check. The changes are mechanical but must all land together — mixed gates create races.

**3.1 — `Features/Chats/Presentation/ChatDetailView.swift` (5 sites):**

- Line 384: `await viewModel.stopTypingIndicator(conversationId:, messageRepository:, canSend: container.privacySettings.canSendTypingIndicators)` → drop the `canSend:` parameter.
- Lines 421-428: the `if container.privacySettings.canSendReadReceipts { try? await container.messageRepository.markAsRead(...) } else { try? await container.messageRepository.markAsReadLocally(...) }` branch collapses to a single `try? await container.messageRepository.markAsRead(...)` call. The repo handles the local fallback.
- Lines 476, 486: typing indicator dispatch calls drop `canSend:`.
- Lines 1221-1228: same `markAsRead` collapse as 421-428.

**3.2 — `Features/Chats/Presentation/ChatDetailViewModel.swift`:**

- `sendTypingIndicator(conversationId:messageRepository:canSend:)` at line 841 — drop the `canSend: Bool` parameter. Method body just calls `messageRepository.sendTypingIndicator(conversationId:, isTyping: true)`.
- `stopTypingIndicator(conversationId:messageRepository:canSend:)` — drop `canSend:`.
- `setTypingIndicator(...)` at line 880 — drop the gate plumb.

**3.3 — `Shared/Services/RealtimeService.swift` (3 sites):**

- Line 187: `if privacySettings.canSendPresence { try? await sendPresenceHeartbeat(.foreground) }` → `try? await sendPresenceHeartbeat(.foreground)`.
- Line 203: same simplification for `.background`.
- Line 364: same simplification inside the reconnect loop.
- `privacySettings` parameter on the initializer stays — it may still be needed for future `isBlocked` checks when filtering inbound events. A minor cleanup pass at the end can remove the parameter entirely if no references remain, but this is a nice-to-have and not required for correctness.

**3.4 — `Features/Chats/Presentation/ChatsListViewModel.swift:270` (`markAsRead(_ conversation:)`):**

- Already routes through `messageRepository.markAsRead`. Inherits the new gate automatically. No code change. Verify with test C-3 below.

**3.5 — `Features/Chats/Domain/ChatUseCases.swift:195, 238`:**

- Both call `messageRepository.markAsRead`. Inherit the new gate. No code change. Verify.

**3.6 — Test doubles and existing tests:**

- Stub `MessageRepositoryProtocol` implementations at `Tests/UnitTests/TestDoubles.swift:269, 271, 288` are no-ops — they don't check anything. Protocol surface is unchanged, so stubs still compile.
- Any test that constructed `MessageRepository` directly with the old init signature breaks at compile time — those tests get the new `privacySettings:` argument, typically `PrivacySettingsCache()`.
- `Tests/UnitTests/SessionServiceTests.swift:32, 51, 107` construct `SessionService(...)` directly. Adding `privacySettings:` to that constructor breaks compilation — update each call site to pass a `PrivacySettingsCache()` instance.
- `Tests/UnitTests/RealtimeServiceTests.swift:122-124` (`makeAuthenticatedSessionService` helper) also constructs `SessionService` — same fix.
- Any test that called `viewModel.sendTypingIndicator(..., canSend: false)` or `stopTypingIndicator(..., canSend:)` breaks at compile time — drop the argument, set the cache state instead.

### 4. Tests

The point of the gate move is to make enforcement automatic and testable. With the `MessagingPrivacyGate` struct factored out of `MessageRepositoryImpl`, the decision logic is fully characterized by a pure struct over a cache — easy to unit test in isolation. The repository-level wiring (every gated method actually consults the gate) is verified by a grep-based invariant during final verification because instantiating `MessageRepositoryImpl` in tests would require ~100+ stub methods across six dependencies (two actors, one concrete final class) — infeasible for this sprint.

**4.1 — New file `Tests/UnitTests/MessagingPrivacyGateTests.swift` (9 tests):**

Tests the `MessagingPrivacyGate` struct directly. Each test builds a fresh `PrivacySettingsCache`, configures it via `update(from:)` with a `Vync_Settings_UserSettings` proto, constructs `MessagingPrivacyGate(privacySettings: cache)`, and asserts the decision. No `MessageRepositoryImpl` instantiation — the gate is a pure struct.

Coverage matrix — 3 signals × 3 flag configurations:

| # | Test name | Signal | Flag state | Expected |
|---|---|---|---|---|
| 1 | `test_readReceipt_defaults_allow` | `.readReceipt` | defaults (readReceipts=true, sanchrMode=false) | `.allow` |
| 2 | `test_readReceipt_disabled_suppress` | `.readReceipt` | readReceipts=false | `.suppress` |
| 3 | `test_readReceipt_sanchrModeOn_suppress` | `.readReceipt` | readReceipts=true, sanchrMode=true | `.suppress` |
| 4 | `test_typingIndicator_defaults_allow` | `.typingIndicator` | defaults | `.allow` |
| 5 | `test_typingIndicator_disabled_suppress` | `.typingIndicator` | typingIndicator=false | `.suppress` |
| 6 | `test_typingIndicator_sanchrModeOn_suppress` | `.typingIndicator` | sanchrMode=true | `.suppress` |
| 7 | `test_presenceHeartbeat_defaults_allow` | `.presenceHeartbeat` | defaults | `.allow` |
| 8 | `test_presenceHeartbeat_onlineStatusOff_suppress` | `.presenceHeartbeat` | onlineStatusVisible=false | `.suppress` |
| 9 | `test_presenceHeartbeat_sanchrModeOn_suppress` | `.presenceHeartbeat` | sanchrMode=true | `.suppress` |

**4.2 — New file `Tests/UnitTests/SessionServicePrivacyClearTests.swift` (2 tests):**

- `test_clearSession_resetsCacheToDefaults` — pre-populate the cache with non-default values, call `sessionService.clearSession()`, assert each getter returns default.
- `test_clearSession_idempotent` — call `clearSession()` twice, second call does not crash; cache stays at defaults.

**4.3 — Extend existing `Tests/UnitTests/PrivacySettingsCacheTests.swift`:**

- `test_clear_resetsAllFields` — covers the new `clear()` method: populate, clear, assert all four primary getters return defaults AND `profilePhotoVisibility == "everyone"` AND `blockedUserIds.isEmpty`.
- `test_updateFromSettings_populatesProfilePhotoVisibility` — round-trip through `update(from:)`.
- `test_updateFromSettings_emptyProfilePhotoVisibilityFallsBackToEveryone` — empty string in proto triggers the fallback.
- `test_isBlocked_reflectsBlockListUpdate` — `update(blockList: ["u1", "u2"])`, `isBlocked("u1") == true`, `isBlocked("u3") == false`.
- `test_concurrentClearAndRead_doesNotCrash` — stress test: run `clear()` concurrently with many reads across multiple getters, assert no crash, no data race.

**4.4 — Gate-wiring invariant (grep-based, not XCTest):**

During the final verification task, three grep checks confirm that `MessageRepositoryImpl.markAsRead`, `sendTypingIndicator`, and `sendPresenceHeartbeat` each contain exactly one call to `privacyGate.decide(...)`, and no `grpcClient.messagingService.sendReceipt` / `streamController.send(...)` invocation appears before the gate branch. These greps run in CI as part of the standard build verification step.

**4.5 — Manual QA on simulator:**

End-to-end verification through the UI. Boot the simulator, sign in, enable Sanchr Mode in Privacy settings, open a chat, send and receive messages, and observe (via server logs, gRPC proxy, or `os_log` on the client) that zero typing / read-receipt / presence frames leave the device. This is the trusted verification of the full view → viewmodel → repo → gRPC chain under Sanchr Mode. Documented in the plan's final verification task.

**4.6 — Snapshot / UI tests:**

Not required for Phase 1. Visual changes (borders removed, dark theme, dead state removal) are simple enough to verify manually on simulator in light and dark modes. If the repo has existing snapshot infrastructure it can be extended later; otherwise deferred.

### 5. File Inventory

**Created (5):**

- `ios/Sanchr-iOS/Shared/Services/MessagingPrivacyGate.swift` — new gate struct.
- `ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift` — extracted from `PrivacyView.swift`.
- `ios/Sanchr-iOS/Features/Settings/Presentation/SanchrModeCard.swift` — extracted from `PrivacyView.swift`.
- `ios/Sanchr-iOS/Tests/UnitTests/MessagingPrivacyGateTests.swift` — 9 gate-decision tests.
- `ios/Sanchr-iOS/Tests/UnitTests/SessionServicePrivacyClearTests.swift` — 2 logout-clear tests.

**Modified (11):**

- `ios/Sanchr-iOS/Features/Settings/Presentation/PrivacyView.swift` — borders removed, dead state deleted, dark theme tokens, subview extractions, ≤ 300 LOC target.
- `ios/Sanchr-iOS/Shared/Services/PrivacySettingsCache.swift` — new fields, `clear()`, extended `update(from:)`, new `update(blockList:)`, new getters.
- `ios/Sanchr-iOS/Shared/Repositories/MessageRepository.swift` — `privacySettings` init dep, `privacyGate` stored property, gate calls in `markAsRead` / `sendTypingIndicator` / `sendPresenceHeartbeat`.
- `ios/Sanchr-iOS/App/DependencyContainer.swift` — thread `privacySettings` into `MessageRepositoryImpl` and `SessionService`.
- `ios/Sanchr-iOS/Shared/Services/SessionService.swift` — `privacySettings` dep, call `privacySettings.clear()` in `clearSessionState()`.
- `ios/Sanchr-iOS/Shared/Services/RealtimeService.swift` — drop the 3 `canSendPresence` guards.
- `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailView.swift` — drop `canSend:` args, collapse `markAsRead` branches.
- `ios/Sanchr-iOS/Features/Chats/Presentation/ChatDetailViewModel.swift` — drop `canSend` parameter from typing methods.
- `ios/Sanchr-iOS/Tests/UnitTests/PrivacySettingsCacheTests.swift` — 5 new tests for clear, profile photo round-trip, isBlocked, concurrent stress.
- `ios/Sanchr-iOS/Tests/UnitTests/SessionServiceTests.swift` — three `SessionService(...)` call sites gain the new `privacySettings:` argument.
- `ios/Sanchr-iOS/Tests/UnitTests/RealtimeServiceTests.swift` — `makeAuthenticatedSessionService` helper gains the new argument.

### 6. Error Handling

- **Gated sends are silent no-ops.** Not errors. A disabled read receipt is expected behavior.
- **`markAsRead` fall-through to `markAsReadLocally`** must still throw on local DB failure. Do not swallow.
- **`clear()` is infallible.** Resets under the lock. No return value.
- **Logout race.** `clearSessionState()` calls `privacySettings.clear()` as its first line. Any in-flight async work that captured a cache reference and is about to call `canSendReadReceipts` will observe the cleared (default) state. Default is permissive — in-flight work proceeds. This is intentional: we prioritize not dropping messages over perfectly atomic logout. The window is sub-millisecond.
- **`loadSettings` failure on login.** Cache retains defaults from the preceding `clear()`. Defaults are permissive (readReceipts on, typing on, presence on, sanchrMode off). A transient network failure on login does not silently disable features the user had enabled on the server.
- **Pre-existing screenshot protection / app lock state.** These are handled through `AppLockManager` separately and are not affected by this refactor.

### 7. Out of Scope (Explicit)

- Backend work (any crate under `backend/`).
- Proto changes.
- Database migrations.
- Paper revisions.
- Profile photo visibility *enforcement* on the client (you see a blank avatar when a contact has visibility=nobody) — needs backend cooperation → Phase 2.
- Blocked contacts inbound message filtering on the client — same reason → Phase 2.
- Last Seen / About visibility as real features — removed, not built.
- Disappearing Messages — removed from Privacy screen; if ever implemented it belongs under Chats settings with full per-conversation TTL support.
- Metadata privacy (Sealed Sender et al.) — separate rollout in `metadata_privacy_plan.md`.

---

## Success Criteria

Phase 1 is complete when:

1. All four `.overlay { .stroke }` borders in `PrivacyView.swift` are gone. Manual verification in light mode.
2. Privacy screen renders correctly in dark mode. Manual verification on simulator.
3. Last Seen, About, Disappearing Messages rows are removed from the Privacy screen.
4. `MessageRepository.markAsRead / sendTypingIndicator / sendPresenceHeartbeat` check `PrivacySettingsCache` before hitting gRPC.
5. `ChatDetailView`, `ChatDetailViewModel`, `RealtimeService` no longer contain any `canSend*` checks (the checks are gone, not just moved).
6. `SessionService.clearSession()` resets `PrivacySettingsCache` to defaults.
7. `PrivacySettingsCache` tracks `profilePhotoVisibility`, `blockedUserIds`, and supports `clear()` / `update(blockList:)`.
8. Unit tests in §4.1, §4.2, §4.3 all pass. The concurrent-stress regression is clean.
9. Gate-wiring grep invariants in §4.4 all pass (every gated method has exactly one `privacyGate.decide` call before any network dispatch).
10. `xcodebuild` is clean (no new warnings, no broken tests) and the existing suite stays green.
11. `PrivacyView.swift` is ≤ 300 LOC.
12. `BlockedContactsView.swift` and `SanchrModeCard.swift` exist and are exercised by the app.

---

## References

- Pandey, Suraj. *Threat-Driven Extensions to the Signal Protocol: Private Contact Discovery, Forward-Secure Media, and Ephemeral Key Management*. Version v0.0.1, 2026-04-08. `web/public/research.pdf`. Sections referenced: §2.4 Threat definitions; §3.2 OPRF-PSI protocol; §4.3.1 Device-local AccessK cache; §5.2.1 Key classes and TTLs; §5.2.2 Expiration policies; §9.1 Limitations (L3 single OPRF key, L6 storage-layer dependence).
- `metadata_privacy_plan.md` — separate rollout covering Phase 4 (Sealed Sender et al.).
- `project_feature_tiers.md` — Signal audit of Sanchr features. Disappearing Messages is listed as already implemented but the Privacy screen toggle for the *default* TTL is not yet wired; Phase 1 removes the dead toggle.
- `2026-04-08-presence-and-receipts-reliability-a1-design.md` — prior spec for the receipt/presence reliability pass (A1 workstream). This Phase 1 builds on the `PrivacySettingsCache` shape defined there.
- `2026-04-09-vault-e2ee-ios.md` — recent vault rewrite that validated D2's client-side AccessK derivation.
