# Presence & Read Receipts Reliability — Phase A1 Design

**Date:** 2026-04-08
**Status:** Approved (brainstorming complete) — ready for implementation plan
**Author:** Sooraj Pandey + Claude
**Scope:** Phase A1 of a four-phase rework. A1 is connection-reliability foundation; A2 is the watermark read-receipt migration; B is privacy / Sanchr Mode correctness; C is UX dead-code cleanup. Each phase is its own spec → plan → implementation cycle.

---

## Problem

> "Online status and read receipts are not efficiently handled. Sometimes it works, sometimes it just misses."

A deep audit of both the iOS client (`/Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS`) and the Rust backend (`/Users/soorajpandey/Projects/zynclave/sanchr/backend`, k8s deployment with 2× `vync-core` pods + NATS) surfaced fifteen substantive defects. The most consequential, ranked:

1. **No transport keepalives anywhere.** Tonic server has no `http2_keepalive_interval`, gRPC client has no equivalent. Half-open TCP connections (mobile network change, NAT timeout, walking through a tunnel) are invisible until OS-level TCP keepalive fires — ~2 hours on Linux defaults. The 90s Redis foreground TTL is the *only* thing that ever notices, and only for foreground users.
2. **No replay on reconnect.** When the bidi `MessageStream` reopens, the server drains queued message envelopes and call events but does **not** replay presence snapshots, typing, or any receipts. A client that drops for 5 seconds during a read-receipt push permanently misses that read receipt.
3. **`markAsRead` failure path drops state.** RPC fails → local SQLite never updated → `unreadCount` stays nonzero → next visit retriggers → infinite loop on bad networks. There is **no offline queue** for read receipts (only delivery acks have one).
4. **Multi-node presence/typing/receipts are broken by construction.** No NATS bridge for any of them — only for `EncryptedEnvelope` messages. Two users on different `vync-core` instances never see each other's live presence/typing/read state. Confirmed broken in current production: 2 vync-core pods serving traffic.
5. **Background-only users never broadcast Offline.** Sweeper handles foreground TTL only; Background→Offline via 6h Redis eviction triggers no recompute, so peers see "online" forever.
6. **Stream send blocks on slow consumers.** `stream_mgr.send_to_user` does serial `await tx.send()` with no timeout — one stuck device stalls every broadcast for that peer.
7. **`User.status` and `User.lastSeen` columns are write-once dead bindings.** Realtime layer never writes them back to SQLite. ChatList green dot, ContactList "X online now", and the `.typing` enum branch in the chat header are *all* reading from never-updated columns.
8. **`PrivacyView` instantiates a fresh `SettingsViewModel()` without `privacySettings: container.privacySettings`.** Toggling "Read Receipts off" pushes to server but never updates the in-memory cache. Read receipts keep firing for the rest of the session.
9. **Read-receipt RPC has zero debounce.** Every incoming message in an open chat fires one unary `SendReceipt` immediately.
10. **`conversation.lastMessageStatus` denorm not updated by `ReceiptUpdate`.** Chat-list double-tick stays grey forever even after the recipient reads — until a *newer* message replaces the row.
11. **Sanchr Mode does not gate presence broadcast on the server.** `compute_aggregate_presence` only consults `online_status_visible`. Sanchr Mode is a partial leak.
12. **No `PresenceUpdate` push when settings flip.** Toggling "hide online status" only invalidates the privacy cache; peers continue seeing the old state.
13. **Blocked-user filtering does not exist** in the messaging/presence/typing/receipt path. `contacts.is_blocked` is in the schema but unused.
14. **Receive-side privacy gate is wrong.** `ChatDetailView.headerStatusText` gates presence rendering on the *local* user's `onlineStatusVisible` setting. Hiding your own presence accidentally also hides everyone else's from you.
15. **`handle_send_receipt` accepts arbitrary status strings, has no idempotency, no rate limit.**

A1 fixes #1–6, #7, #8, #10. A2 fixes the read-receipt watermark migration which subsumes #3 and #9. Phase B fixes #11–15.

---

## Decisions locked during brainstorming

| Decision | Choice | Rationale |
|---|---|---|
| Phasing | A1 → A2 → B → C as separate spec cycles | Smaller blast radius per merge; matches the CLAUDE.md "phased execution" directive |
| Deployment | Multi-node (2× vync-core in k8s today) | NATS bridge for live state is critical-path, not future-prep |
| Presence freshness | Balanced: 30s heartbeat / 75s FG TTL / 10s sweeper | Signal-ish UX, reasonable battery |
| Read state model | Watermark per (conversation, reader), per-message stays for delivered | Idempotent, offline-safe, matches WhatsApp/Signal — but the watermark migration itself ships in A2, not A1 |
| Multi-device read sync | Yes, fan watermark to reader's other devices | Almost-free win in A2 |
| Group chats | Typing yes, presence stays direct-only | Typing is high-value UX, presence in groups scales poorly and has privacy implications |
| Stream architecture | Keep one bidi stream multiplexing everything | Minimal proto/server churn; fix the bottlenecks instead of splitting |

---

## A1 Architecture Overview

The high-level shape doesn't change. We're tightening every weak link in the existing chain.

### New cross-node fan-out path (NATS)

```
[client A on pod btdjt]                        [client B on pod fqwrf]
        │                                                ▲
        │  ClientEvent.heartbeat                         │  ServerEvent.presence
        ▼                                                │
[vync-core@btdjt]                                 [vync-core@fqwrf]
   handle_presence_heartbeat                         relay_bridge.subscribe
        │                                                ▲
        ├─ apply_device_state_change                     │
        │     ├─ Redis: SET presence:device:…            │
        │     ├─ PG: update_presence_state               │
        │     └─ broadcast_presence                      │
        │           ├─ local stream_mgr.send_to_user     │
        │           └─ NATS publish ─────────────────────┘
        │              "presence.fanout.{user_id}"
        ▼
   (return Ok)
```

Same shape for `TypingIndicator` (`typing.fanout.{user_id}`) and `ReceiptUpdate` (`receipt.fanout.{user_id}`).

### Snapshot replay on stream open

After auth on `MessageStream`, the spawned task already calls `handle_sync_messages` and `drain_call_events`. We add a third: `replay_presence_snapshot_for_direct_peers(user_id)`. It calls `pg_conv::get_direct_peer_ids`, then `compute_aggregate_presence` for each, and pushes one `ServerEvent.PresenceUpdate` per peer through `forward_tx` before live events. Hard cap at 200 peers (warn-log if over).

### Sweeper for background expiry

A second sorted set `presence:background_expiry` is populated by `set_device_presence(state=Background)` with score `now + 21_600_000`. Sweeper polls both sets every 10s. When a background key expires, recompute aggregate and broadcast Offline. Pop is done via a Lua script for race-free atomicity across pods.

### Per-target backpressure

`stream_mgr.send_to_user` switches from serial `tx.send().await` to:
- `tx.try_send(event)` for ephemeral events (presence, typing) — drop on full
- `tx.send_timeout(event, 500ms)` for durable events (messages, receipts) — log + skip target on timeout

### Client write-through

`RealtimeService.handle(.presence)` adds a write-through to `LocalDatabase.updateUserPresence(userId, status, lastSeen)` so the SQLite `user.status` and `user.lastSeen` columns get refreshed. ChatsListView and ContactsView green dots immediately come alive — no other code change needed because they already read from `User.status`.

### `PrivacyView` cache wiring

Fix `PrivacyView` to pass `privacySettings: container.privacySettings` into `SettingsViewModel.loadSettings`. One-line fix; the load-bearing one — this is why "I turned off read receipts and they kept sending."

### Chat-list denorm refresh

`MessageRepository.openMessageStream`'s `case .receipt:` arm now also updates `conversation.lastMessageStatus` if the receipt is for the conversation's current `lastMessageId`.

---

## Server-side changes (Rust)

### Tonic HTTP/2 keepalive (vync-core/src/main.rs)

Add to the server builder:

```rust
.http2_keepalive_interval(Some(Duration::from_secs(20)))
.http2_keepalive_timeout(Some(Duration::from_secs(10)))
.tcp_keepalive(Some(Duration::from_secs(30)))
.tcp_nodelay(true)
```

20s keepalive ping with 10s timeout means a half-open TCP is detected within 30s instead of ~2 hours.

### NATS bridge for live state

**New NATS subjects** (recipient-keyed so each pod only receives events it has streams for):
- `presence.fanout.{recipient_user_id}`
- `typing.fanout.{recipient_user_id}`
- `receipt.fanout.{recipient_user_id}`

Each subject carries a serialized `ServerEvent` (proto bytes — same wire format as the gRPC stream).

**Publish side** — modify the three broadcast helpers:
- `presence::handlers::broadcast_presence_to_direct_peers` — for each direct peer, in addition to local `stream_mgr.send_to_user`, also `nats.publish("presence.fanout.{peer_id}", server_event_bytes)`.
- `presence::handlers::handle_typing` — same pattern with `typing.fanout.{peer_id}`.
- `messaging::handlers::handle_send_receipt` and `handle_ack_messages` — same pattern with `receipt.fanout.{peer_id}`.

**Subscribe side** — extend `relay_bridge` with three new subscriptions on startup:
- `nats.subscribe("presence.fanout.*")` → on each message, parse user_id from the subject, look up local streams via `stream_mgr.send_to_user`, drop if no local recipients.
- Same for `typing.fanout.*` and `receipt.fanout.*`.
- **Loop-prevention**: each publish includes a `source_pod_id` header (`vync-core-{hostname}`); subscriber drops messages where header == own pod id.

### Sweeper extensions

**New Redis ZSET**: `presence:background_expiry`. `set_device_presence(state=Background, ...)` adds the device key to this ZSET with score `now_ms + 21_600_000` (6h). State transitions BG→FG or BG→Offline ZREM the entry. State transition FG→BG adds the entry and removes from `presence:foreground_expiry`.

**Sweeper loop change** (`spawn_presence_sweeper`):
- Tick every **10s** (down from 15s).
- Pop expired keys from BOTH zsets.
- For each, call `apply_device_state_change(... OfflineDevice ...)` which already broadcasts on the diff.

**Race-free pop**: replace `ZRANGEBYSCORE + ZREM` with a single Lua script `presence_pop_expired.lua`:

```lua
local expired = redis.call("ZRANGEBYSCORE", KEYS[1], "-inf", ARGV[1])
if #expired > 0 then redis.call("ZREM", KEYS[1], unpack(expired)) end
return expired
```

Atomic, EVAL-safe, eliminates the double-sweep race across pods.

### Snapshot replay on stream open

In `MessagingService::message_stream`, after the existing `handle_sync_messages` and `drain_call_events` calls, add:

```rust
presence::handlers::replay_presence_snapshot_for_direct_peers(
    state.clone(),
    user_id,
    forward_tx.clone(),
).await;
```

**New function** in `presence/handlers.rs` (pseudocode — implementation will use the existing error-handling style of the surrounding module):

```text
pub async fn replay_presence_snapshot_for_direct_peers(
    state: AppState,
    user_id: Uuid,
    forward_tx: mpsc::Sender<Result<ServerEvent, Status>>,
) {
    // Errors here are logged and the function returns early — replay
    // failure must NOT prevent the MessageStream from opening.
    let peers = pg_conv::get_direct_peer_ids(&state.pg, user_id).await
        .unwrap_or_default();

    let mut count = 0;
    for peer_id in peers.iter().take(MAX_SNAPSHOT_REPLAY_PEERS) {
        let aggregate = match compute_aggregate_presence(&state, *peer_id).await {
            Ok(a) => a,
            Err(e) => { tracing::warn!(?e, peer_id = %peer_id, "snapshot peer compute failed"); continue; }
        };
        let update = match presence_update_for(*peer_id, aggregate, &state).await {
            Ok(u) => u,
            Err(e) => { tracing::warn!(?e, peer_id = %peer_id, "snapshot peer build failed"); continue; }
        };
        let event = ServerEvent { event: Some(server_event::Event::Presence(update)) };
        if forward_tx.send(Ok(event)).await.is_err() { break; }
        count += 1;
    }
    metrics::histogram!("presence_snapshot_replay_peers").record(count as f64);

    if peers.len() > MAX_SNAPSHOT_REPLAY_PEERS {
        tracing::warn!(
            user_id = %user_id,
            total = peers.len(),
            cap = MAX_SNAPSHOT_REPLAY_PEERS,
            "presence snapshot replay capped"
        );
    }
}
```

`MAX_SNAPSHOT_REPLAY_PEERS = 200` (hard cap; if a user has more than 200 direct peers, sort by `last_active_at DESC` server-side in `get_direct_peer_ids` to pick the most-active 200 — schema work is a single ORDER BY).

### Per-target backpressure (messaging/stream.rs)

Refactor `StreamManager::send_to_user`:

```rust
pub async fn send_to_user(&self, user_id: &str, event: ServerEvent, durability: Durability) -> usize {
    let txs = self.streams_for(user_id).await;
    let mut delivered = 0;
    for tx in txs {
        match durability {
            Durability::Ephemeral => {
                if tx.try_send(Ok(event.clone())).is_ok() { delivered += 1; }
            }
            Durability::Durable => {
                match tokio::time::timeout(Duration::from_millis(500), tx.send(Ok(event.clone()))).await {
                    Ok(Ok(())) => delivered += 1,
                    _ => tracing::warn!(user_id, "stream send timeout, skipping target"),
                }
            }
        }
    }
    delivered
}
```

**Call-site annotation**: `broadcast_presence_to_direct_peers` and `handle_typing` use `Durability::Ephemeral`. `handle_send_receipt`, `handle_ack_messages`, and `router::route_message` use `Durability::Durable`. Default for `relay_bridge` inbound from NATS is `Ephemeral` for presence/typing subjects, `Durable` for receipt/message subjects.

### Files touched (server side)

1. `crates/vync-core/src/main.rs` — keepalive config + sweeper interval
2. `crates/vync-core/src/messaging/stream.rs` — `Durability` enum, `send_to_user` refactor
3. `crates/vync-core/src/messaging/relay_bridge.rs` — subscribe to 3 new subjects, dedupe by source_pod_id
4. `crates/vync-core/src/messaging/service.rs` — `replay_presence_snapshot` call site after sync drain
5. `crates/vync-core/src/messaging/handlers.rs` — publish to NATS in receipt + ack handlers, add `Durability::Durable` to existing `send_to_user` calls
6. `crates/vync-core/src/messaging/router.rs` — `Durability::Durable` annotation only
7. `crates/vync-core/src/presence/handlers.rs` — `replay_presence_snapshot_for_direct_peers`, NATS publish, dual-zset sweep, `Durability` annotations
8. `crates/vync-db/src/redis/presence.rs` — `presence:background_expiry` zset, Lua-script-based pop, dual-sweep helper

Eight files — split into ~3 implementation sub-phases (`server-keepalive-and-sweeper`, `server-nats-bridge`, `server-snapshot-and-backpressure`).

### What's deliberately NOT in A1 (server)

- No Sanchr Mode gating for presence (Phase B).
- No blocked-user filtering (Phase B).
- No watermark proto / new RPC (Phase A2).
- No SQL migrations (A2 will add `conversation_participants.last_read_message_id`).
- No proto changes — wire format unchanged.

---

## Client-side changes (iOS Swift)

### `PrivacyView` cache wiring (the load-bearing one-line fix)

**File:** `Features/Settings/Presentation/PrivacyView.swift`

```swift
.task {
    await viewModel.loadSettings(
        settingsDataSource: container.settingsDataSource,
        privacySettings: container.privacySettings   // ← currently missing
    )
}
```

`SettingsViewModel.loadSettings` and `applySettings` already accept that parameter — `SettingsView.swift` passes it correctly. With this fix, toggling "Read Receipts off" inside Privacy immediately propagates into `PrivacySettingsCache`.

### Presence write-through into local SQLite

**Files:** `Shared/Services/RealtimeService.swift`, `SanchrShared/Persistence/LocalDatabase.swift`

`RealtimeService.handle(_ presence:)` currently only updates `presenceCache` and posts a notification. Add:

```swift
private func handle(_ presence: Vync_Messaging_PresenceUpdate) {
    presenceCache[presence.userID] = presence
    Task.detached { [localDatabase] in
        try? await localDatabase.updateUserPresence(
            userId: presence.userID,
            status: User.Status(from: presence.statusCode),
            lastSeen: presence.lastSeen > 0
                ? Date(timeIntervalSince1970: TimeInterval(presence.lastSeen) / 1000.0)
                : nil
        )
    }
    NotificationCenter.default.post(
        name: .sanchrRealtimePresenceUpdated,
        object: nil,
        userInfo: [RealtimeNotificationKey.presence: presence]
    )
}
```

`User.Status(from: PresenceStatus)` is a new mapping helper in `SanchrShared/Models/User.swift`:

```swift
init(from code: Vync_Messaging_PresenceStatus) {
    switch code {
    case .online:  self = .online
    case .offline: self = .offline
    case .hidden:  self = .offline   // hidden looks like offline locally
    case .presenceStatusUnspecified, .UNRECOGNIZED: self = .offline
    }
}
```

`LocalDatabase.updateUserPresence(userId:status:lastSeen:)` is a new method:

```swift
func updateUserPresence(userId: String, status: User.Status, lastSeen: Date?) async throws {
    try await dbWriter.write { db in
        try db.execute(sql: """
            UPDATE user
            SET status = ?, lastSeen = ?
            WHERE id = ?
        """, arguments: [status.rawValue, lastSeen, userId])
    }
}
```

After this lands, `ChatsListView.statusDot`, `ChatsListView`'s "typing..." preview, `ContactsView`'s green dot, and `ContactsViewModel.onlineCount` all start working with zero changes.

### Chat-list denorm refresh on incoming receipt

**File:** `Shared/Repositories/MessageRepository.swift`

In `openMessageStream`'s `case .receipt:` arm, after the existing `localDatabase.updateMessageStatus(...)`:

```swift
case .receipt(let receipt):
    if let status = Message.DeliveryStatus(rawValue: receipt.status) {
        try? await localDatabase.updateMessageStatus(id: receipt.messageID, status: status)
        try? await localDatabase.updateConversationLastMessageStatusIfMatches(
            conversationId: receipt.conversationID,
            messageId: receipt.messageID,
            status: status
        )
    }
    continuation.yield(.receipt(receipt))
```

`updateConversationLastMessageStatusIfMatches` only updates `conversation.lastMessageStatus` when the receipt is for the conversation's CURRENT `lastMessageId`. No update if a newer message has already replaced the row.

### NetworkMonitor → RealtimeService observation (kill the 2s tight retry spin)

**Files:** `Shared/Services/NetworkMonitor.swift`, `Shared/Services/RealtimeService.swift`

Currently `RealtimeService.start()` sleeps a flat 2s and retries forever. On a wifi flap that means a tight reconnect loop hammering gRPC. Replace with:

```swift
private func reconnectBackoff(attempt: Int) -> Duration {
    let base: Double = 1.0
    let cap: Double  = 30.0
    let exponential = min(cap, base * pow(2.0, Double(attempt)))
    let jitter = Double.random(in: 0...exponential * 0.3)
    return .seconds(exponential + jitter)
}
```

Reset `attempt` to 0 on:
- Successful stream open
- `NetworkMonitor` reports network newly available (force immediate reconnect)

Cancel any pending retry sleep when `NetworkMonitor` reports network down.

`NetworkMonitor` gains a Combine `Publisher<Bool, Never>` (or AsyncStream) of network status. Currently it only logs to OSLog.

### Heartbeat cadence retune

**File:** `Shared/Services/RealtimeService.swift`

`startHeartbeatLoop` keeps its 30s sleep — that matches the new "balanced" target. Add a code comment that 30s is paired with the server's 75s foreground TTL (one missed heartbeat is forgiven, two consecutive misses flip to offline).

Confirm the loop doesn't double-send the first heartbeat (the explicit `sendPresenceHeartbeat(.foreground)` in `enterForeground` should not be repeated by the loop's first iteration).

### `ChatDetailView` header presence gate fix

**File:** `Features/Chats/Presentation/ChatDetailView.swift`

`loadHeaderPreferences` currently sources `showsPresence` from the LOCAL user's `settings.onlineStatusVisible`. That's wrong — hiding *my* presence shouldn't hide everyone else's from me. The peer's visibility is conveyed by the server via `PresenceStatus.hidden`, which `ChatDetailViewModel.handlePresenceUpdate` already maps to `peerPresenceHidden`.

Fix: drop the local-user gate.

```swift
viewModel.configurePeer(recipient, showsPresence: true, ...)
```

`showsPresence` becomes a no-op flag we can delete in a follow-up cleanup; for A1 just stop conflating the two semantics.

### Snapshot replay handling on the client

The server now pushes a presence snapshot per direct peer at stream open. The client doesn't need any new handler — `RealtimeService.handle(.presence)` already handles `PresenceUpdate` arrivals, and they'll just flow through the new write-through into SQLite. Add one debug log:

```swift
SanchrLogger.realtime.debug("presence update userId=\(presence.userID) code=\(presence.statusCode.rawValue)")
```

### Files touched (client side)

1. `Features/Settings/Presentation/PrivacyView.swift` — one-line cache wire-up
2. `Shared/Services/RealtimeService.swift` — write-through call, backoff with jitter, network observation, debug log
3. `Shared/Services/NetworkMonitor.swift` — add Combine publisher / AsyncStream
4. `Shared/Repositories/MessageRepository.swift` — denorm refresh on receipt
5. `SanchrShared/Persistence/LocalDatabase.swift` — `updateUserPresence`, `updateConversationLastMessageStatusIfMatches`
6. `SanchrShared/Models/User.swift` — `User.Status(from: PresenceStatus)` initializer
7. `Features/Chats/Presentation/ChatDetailView.swift` — drop the wrong-direction privacy gate

7 files. Will likely split into 2 implementation sub-phases (`client-presence-write-through-and-cache-fix` and `client-network-observation-and-denorm`).

### What's deliberately NOT in A1 (client)

- No `markAsRead` retry queue (subsumed by A2's watermark).
- No debounce on `markAsRead` (subsumed by A2).
- No `User.Status.away` removal (Phase C dead code cleanup).
- No background-task registration to keep the stream alive while backgrounded.

---

## Failure modes & rollout

### Failure modes

**NATS unreachable** — `relay_bridge` already tolerates NATS startup races. We extend the same pattern: subscriber retries with exponential backoff. Publisher path treats NATS publish as best-effort — if `nats.publish(...).await` errors, log and continue. Same-pod peers still receive the event via the local `stream_mgr.send_to_user`. Cross-pod fan-out degrades to local-only when NATS is down, but the system stays functional.

**Sweeper race across pods** — eliminated by the Lua script `presence_pop_expired.lua`. `EVAL` is atomic in Redis. Even if a duplicate slips through (Redis cluster failover edge case) the only cost is a second PG write and a second broadcast. The diff check (`previous != current`) collapses the second broadcast to a no-op.

**Snapshot replay failure on stream open** — wrap `replay_presence_snapshot_for_direct_peers` in `tokio::spawn` + try/catch. If PG is slow or one peer fetch errors, log and skip that peer. The stream **still opens** even if replay fully fails.

**Tonic keepalive false positives** — if a client is on a high-latency network and a 10s keepalive timeout is too tight, the server will close the stream. Client's `RealtimeService` has the new exponential backoff so reconnect storms are bounded. If we see complaints, raise to `keepalive_interval = 30s` / `timeout = 15s` via config.

**Background-expiry sweeper false positives** — adding a key to the BG zset on FG→BG then forgetting to remove it on BG→FG would mean the device gets prematurely flipped to Offline 6h after BG. Test coverage explicitly verifies the BG→FG transition removes the BG zset entry.

**`updateUserPresence` write contention on iOS** — every incoming presence update triggers a SQL UPDATE on the `user` table. Done in a `Task.detached` with a single-row update, no transaction. GRDB serializes writes anyway. If we ever see queue buildup we add a 1s coalescing window per `userId`.

**`PrivacyView` race on settings push** — `pushSettings` is debounced 500ms server-side. If the user toggles 3 times in 200ms then leaves the screen, the cache update happens immediately (synchronous via `applySettings`) but the server may receive only the final state. This is correct — local enforcement is instant, server is eventually-consistent.

**Stream open during a network flap** — `NetworkMonitor` reports network down → `RealtimeService` cancels its retry sleep and waits for next "network up". This eliminates the tight 2s spin loop. When network comes back, retry attempt resets to 0.

**Backwards compat with old clients** — A1 changes server behavior but not the wire format. An old iOS client will still:
- Receive presence broadcasts (push compatible).
- Receive snapshot replay on stream open (extra unsolicited PresenceUpdate events — the existing handler accepts them).
- Send heartbeats unchanged.
- Send markAsRead unchanged.

No client-side update required for the server portion of A1 to work.

### Rollout sequence

The dependencies form a partial order. We can ship in five increments without breaking anything:

**Increment 1 — Server reliability foundation**
- Tonic HTTP/2 keepalives (`main.rs`)
- Lua-script-based race-free pop (`redis/presence.rs`)
- BG zset + dual-sweep (`presence/handlers.rs`, `redis/presence.rs`)
- `Durability` enum + per-target backpressure (`stream.rs`, all callers)

Ships independently. No client changes required.

**Increment 2 — Cross-pod NATS bridge**
- `relay_bridge` adds 3 new subjects with source-pod-id loop prevention.
- `presence/handlers`, `messaging/handlers` publish to NATS in addition to local fan-out.

Depends on Increment 1's `Durability` enum. Independently shippable.

**Increment 3 — Snapshot replay on reconnect**
- `replay_presence_snapshot_for_direct_peers` in `presence/handlers`.
- Call site in `messaging/service::message_stream` after sync drain.

Independent of Increments 1 and 2.

**Increment 4 — Client write-through and quick fixes**
- `PrivacyView` cache wire-up.
- `RealtimeService` write-through to SQLite.
- `LocalDatabase.updateUserPresence` + `User.Status(from:)`.
- Chat-list denorm refresh.
- `ChatDetailView` header gate fix.

Ships in one client release. Independent of server increments.

**Increment 5 — Client network observation + backoff**
- `NetworkMonitor` Combine publisher.
- `RealtimeService` exponential backoff with jitter, network-up trigger.

Ships in same or next client release as Increment 4.

Server ships 1→2→3 over a few days. Clients ship 4 and 5 together whenever ready. Server changes are forward-compatible with old clients; client changes don't require server changes to land.

### Observability — new metrics + logs

**Server metrics** (Prometheus):
- `presence_broadcast_total{kind="local|nats", recipient_pod="self|other"}` counter
- `presence_snapshot_replay_peers` histogram (buckets: 0, 1, 5, 25, 100, 200)
- `presence_sweeper_evicted_total{set="foreground|background"}` counter
- `stream_send_dropped_total{durability="ephemeral|durable", reason="full|timeout"}` counter
- `tonic_keepalive_disconnect_total` counter

**Server logs** (info, structured):
- `presence_snapshot_replay user_id=… peer_count=… elapsed_ms=…`
- `nats_relay_loop_dropped subject=… source_pod_id=…` (debug)
- `sweeper_tick set=… expired=…`

**Client logs** (`SanchrLogger.realtime`):
- `presence_writethrough user=… status=… last_seen=…` (debug)
- `realtime_reconnect attempt=… backoff_seconds=… reason=network_up|stream_error|…`
- `privacy_cache_updated read_receipts=… typing=… presence=… sanchr_mode=…`

### Configuration knobs (env vars)

- `VYNC_TONIC_KEEPALIVE_INTERVAL_SECS=20`
- `VYNC_TONIC_KEEPALIVE_TIMEOUT_SECS=10`
- `VYNC_PRESENCE_SWEEPER_INTERVAL_SECS=10`
- `VYNC_PRESENCE_FOREGROUND_TTL_SECS=75`
- `VYNC_PRESENCE_BACKGROUND_TTL_SECS=21600`
- `VYNC_PRESENCE_SNAPSHOT_REPLAY_CAP=200`
- `VYNC_NATS_FANOUT_ENABLED=true` (kill switch)

The kill switch on the NATS bridge lets us roll back Increment 2 to local-only without redeploying.

---

## Test plan

### Server unit tests (Rust)

**`vync-core/src/messaging/stream.rs`**
- `try_send_drops_when_channel_full` — fill a 256-cap channel, call `send_to_user(... Ephemeral)`, assert returned `delivered == 0` and the drop counter incremented.
- `send_timeout_skips_slow_target` — register a stream that never reads, call `send_to_user(... Durable)`, assert it returns within ~500ms with `delivered == 0`.
- `mixed_targets_one_slow_one_fast` — two registered streams, one full, one ready. Assert the fast one delivers and the slow one doesn't block it.

**`vync-core/src/presence/handlers.rs`**
- `background_zset_add_on_fg_to_bg_transition` — set FG, then BG. Assert key present in `presence:background_expiry`, absent from `presence:foreground_expiry`.
- `background_zset_remove_on_bg_to_fg_transition` — reverse. Assert removed.
- `background_expiry_triggers_offline_broadcast` — manually expire a BG entry, run sweeper, assert peer received `PresenceUpdate { status: Offline }`.
- `replay_presence_snapshot_for_direct_peers_caps_at_200` — seed 250 direct peers, run replay, assert exactly 200 events pushed (oldest by `last_active_at` skipped, with a warn log).
- `replay_presence_snapshot_skips_failed_peer_compute` — make one peer's `compute_aggregate_presence` error, assert other peers still get pushed.

**`vync-db/src/redis/presence.rs`**
- `pop_expired_lua_atomicity` — concurrent tokio tasks calling `pop_expired_foreground_keys` with overlapping windows; assert union of returned keys equals seeded expired keys, no key returned twice.

**`vync-core/src/messaging/relay_bridge.rs`**
- `nats_loop_prevention_drops_own_publish` — publish a presence event with `source_pod_id` matching self, assert subscriber drops it without calling `stream_mgr.send_to_user`.
- `nats_inbound_routes_to_local_streams` — register a local stream for user X, publish to `presence.fanout.X`, assert local stream received the event.

### Server integration tests (Rust)

Extend the existing `crates/vync-core/tests/presence_flow.rs`:

- `keepalive_detects_half_open` — open `MessageStream`, simulate half-open by holding the inbound side, assert server tears down the stream within ~30s and `apply_device_state_change(Offline)` was triggered.
- `snapshot_replay_on_stream_open` — seed 3 direct peers in `presence:device:*`, open a fresh `MessageStream`, drain `forward_tx`, assert 3 `PresenceUpdate` events arrived before any other event type.
- `cross_pod_fanout_via_nats` — spin up two `vync-core` instances in the test harness sharing a Redis + NATS, register a stream for user A on instance 1, broadcast a presence update for user B from instance 2, assert user A's stream on instance 1 received the event within 100ms.
- `background_only_user_flips_offline_via_sweeper` — set a device to BG, fast-forward Redis TTL, run sweeper, assert `users.last_seen_at` updated and a peer stream received `Offline`.
- `ephemeral_drop_does_not_break_subsequent_sends` — fill a target channel, broadcast a Typing (Ephemeral) — drops. Then drain and broadcast another Typing — assert second one delivers.

### Client unit tests (Swift)

**`Tests/RealtimeServiceTests.swift`**
- `presenceWriteThrough_persistsToLocalDatabase` — feed a `PresenceUpdate` into `RealtimeService.handle`, assert `LocalDatabase.updateUserPresence` was called with mapped status and lastSeen.
- `reconnectBackoff_resetsOnNetworkUp` — simulate 3 failed reconnects, publish a NetworkMonitor "up" event, assert next attempt's backoff is 0.
- `reconnectBackoff_jitterWithinExpectedRange` — call `reconnectBackoff(attempt:5)` 1000 times, assert all values fall in `[32s, 41.6s]`.

**`Tests/MessageRepositoryTests.swift`**
- `receiptHandler_updatesConversationDenormWhenLastMessageMatches` — seed conversation with `lastMessageId = X`, push `ReceiptUpdate { messageId: X, status: read }`, assert `conversation.lastMessageStatus == "read"`.
- `receiptHandler_doesNotUpdateConversationDenormWhenLastMessageDiffers` — same, but `lastMessageId = Y`, receipt for X. Assert no change.

**`Tests/LocalDatabaseTests.swift`**
- `updateUserPresence_persistsAcrossReopen` — write status + lastSeen, close DB, reopen, read row, assert values match.
- `updateUserPresence_writesNullLastSeenWhenZero` — pass nil lastSeen, assert column is NULL not 0.

**`Tests/PrivacySettingsCacheTests.swift`**
- `privacyView_loadSettings_updatesCache` — instantiate the bound view-model with a real cache, call `loadSettings(... privacySettings:)`, assert cache updates. Regression test for the load-bearing fix.

### Manual smoke matrix

Run on staging with two devices (Phone A on pod btdjt, Phone B on pod fqwrf — confirm by `kubectl logs` showing the connection on each pod):

| # | Scenario | Expected |
|---|---|---|
| 1 | A foregrounds → B already in chat with A | B sees "Online now" within 1s |
| 2 | A backgrounds → B watching | B sees "Last seen just now" within 1s |
| 3 | A force-quits → B watching | B sees "Last seen just now" within ≤30s (TCP keepalive) |
| 4 | A walks into elevator (no clean disconnect) | B sees "Last seen X ago" within ≤30s |
| 5 | A reads B's message in chat | B's chat-list shows blue ticks within 1s |
| 6 | A toggles "Read Receipts off" in Privacy → reads B's message | B's chat-list shows grey ticks (no read receipt) — same session, no app restart |
| 7 | Pod fqwrf restarted while B is connected | B reconnects, sees fresh presence for all direct peers within 2s of reconnect |
| 8 | NATS pod killed, A heartbeats | B (other pod) does NOT see A's update (degraded). NATS recovers → next heartbeat propagates everywhere |
| 9 | Toggle airplane mode on A 5 times in 30s | Reconnect attempts use jittered backoff, no tight spin in logs |
| 10 | Group chat, A typing | Group members see "A is typing" — even cross-pod (NATS bridge handles it) |

Pass = all 10 row outcomes match.

### Verification gates per increment

Per the CLAUDE.md "FORCED VERIFICATION" rule, every increment must pass:
- `cargo test -p vync-core` (server)
- `cargo clippy --workspace -- -D warnings` (server)
- `xcodebuild -scheme Sanchr -destination 'generic/platform=iOS'` (client)
- `swift test` for unit tests on the SanchrShared package (client)
- The specific manual smoke matrix rows that are in scope for that increment (e.g., Increment 1 doesn't include cross-pod tests since the NATS bridge isn't in until Increment 2)

No increment is "done" until verification gates pass. Bugs found during smoke get added as new test cases before they're fixed.

---

## Open questions / explicit non-decisions

These are intentionally NOT settled in A1; they belong to a later phase or to operations:

1. **Should we add a load-test harness?** No existing one in `vync-core`. Defer to "monitor in staging for 24h after Increment 1 ships and watch the new metrics."
2. **Should we surface a "presence connection status" indicator in the iOS UI?** Not in A1. C-phase candidate.
3. **Should `last_seen` precision be reduced for privacy (e.g., round to nearest 5 minutes)?** Phase B candidate — coupled with the "hide last seen separately from hide online" toggle.
4. **Should `User.Status.away` be implemented or removed?** Phase C cleanup.
5. **Should we add a per-(conversation, device) typing throttle on the server?** Not in A1. The `typing.fanout.{user_id}` subject already coalesces at the recipient level via the per-target backpressure.

---

## Acceptance criteria for A1 done

A1 ships when ALL of:
- All five increments deployed to production.
- All server unit + integration tests passing in CI.
- All client unit tests passing in CI.
- Manual smoke matrix rows 1–10 all pass on real devices in staging.
- New Prometheus metrics visible in dashboards.
- 24h post-deploy: zero increase in error rate, `tonic_keepalive_disconnect_total` shows non-zero (proves keepalives are working), `presence_sweeper_evicted_total{set="background"}` shows non-zero (proves BG sweep is working), `presence_broadcast_total{kind="nats"}` shows non-zero (proves cross-pod is working).
- No regression in existing message delivery latency or error rate.

---

## Next phases (out of scope for A1)

- **Phase A2** — Watermark read receipts: new `MarkConversationRead` proto + `ConversationReadUpdate` event, PG migration adds `last_read_message_id` column, client offline queue, multi-device read fan-out, deprecation of legacy `SendReceipt(status="read")`.
- **Phase B** — Privacy & Sanchr Mode correctness: server gates Sanchr Mode for presence, broadcast on settings flip, blocked-user filter on send + receive sides, fix the receive-side gate, server-side status validation + idempotency for receipts.
- **Phase C** — UX cleanup: kill `User.Status.away`, debounce read receipts (subsumed by A2 watermark), kill dead `MarkAsReadUseCase`, remove `RealtimeService.cachedPresence(for:)` dead helper, clean up the redundant `showsPresence` flag.
