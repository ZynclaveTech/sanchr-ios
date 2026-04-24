# Sanchr iOS — Production Readiness Roadmap

**Created:** 2026-04-24
**Source:** Audit of `ios/Sanchr-iOS/` on main (verified against current source — see per-phase plans for validated line refs).

**Goal:** Close the gap between current state and App Store / production readiness, phase by phase, with each phase shippable on its own and bounded by the project's `CLAUDE.md` rules (≤5 files per phase, explicit approval between phases, verify before claiming done).

---

## Ordering (confirmed with user 2026-04-24)

User reprioritized: **Calls is P0**. Remaining phases slot in below. Compliance/release-blocker work still needs to happen before any App Store submission but is being deferred behind correctness fixes per user direction.

| # | Phase | Why here | Plan |
|---|-------|---------|------|
| P0 | **Calls hardening** | Multi-device recipients cannot receive calls today (hardcoded `deviceId: 1`). Dead feature flags mask production behavior. Explicit user priority. | [`2026-04-24-ios-calls-hardening.md`](2026-04-24-ios-calls-hardening.md) |
| P1 | Release blockers / compliance | Required before App Store submission: `PrivacyInfo.xcprivacy`, export-compliance review, env/scheme hardening, cert-pinning wiring or removal. | TBD — draft after P0 |
| P2 | Data integrity / upgrade safety | App Group keychain migration (legacy read + resave); pending→confirmed message transaction atomicity; fix test crashes caused by unit tests hitting production App Group paths. | TBD |
| P3 | Messaging correctness | Client idempotency key in `SendMessageRequest` + server enforcement; correct retry semantics for `EncryptedMessageSendingClient`. | TBD |
| P4 | Concurrency hardening | `@MainActor` / actor isolation for `NetworkMonitor`, `SyncState`, `AppLockManager`, and siblings flagged as unsafe observable state. | TBD |
| P5 | Code-quality / hygiene | Share-extension version mismatch; bundled font registration; splits for `CallManager.swift` (1864 LOC), `MessageRepository.swift` (1537), `LocalDatabase.swift` (1506); real UI-test launch hooks. | TBD |

---

## Conventions (apply to every phase)

### Commit authorship
Per `memory/feedback_commit_authorship.md`: **never** use `Co-Authored-By: noreply@anthropic.com`. Commit as the user only.

### Verification (this is a Swift/Xcode project, not a Node/TS project)
`CLAUDE.md` rule 4 mandates running type-check + lint before claiming completion. Swift has no direct `tsc`/`eslint`; substitute:

```bash
# Fast structural check of the iOS target
xcodebuild -workspace ios/Sanchr-iOS/Sanchr.xcworkspace \
  -scheme Sanchr \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build 2>&1 | tail -40

# Unit tests (full)
xcodebuild -workspace ios/Sanchr-iOS/Sanchr.xcworkspace \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation \
  test 2>&1 | tail -60

# Focused test run (per phase)
xcodebuild -workspace ios/Sanchr-iOS/Sanchr.xcworkspace \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SanchrTests/CallManagerE2EETests \
  -skipPackagePluginValidation \
  test 2>&1 | tail -30
```

**No SwiftLint / SwiftFormat is wired in the repo as of 2026-04-24.** If a phase wants lint-style coverage, add the tool as part of P5 hygiene, not inline.

### Server coordination
Several phases (notably P0 Calls, P3 Messaging) require matching backend work. Each phase plan states what the server must ship and designs the iOS change to be backward-compatible when the server hasn't caught up (absent proto field → fall back to today's behavior). **The iOS engineer should not block on server completion**, but should coordinate rollout order in a release note.

### Scope of a "phase"
Each phase produces:
1. A standalone plan doc in this directory.
2. Green test suite on completion.
3. A git commit per sub-phase (small, reviewable, revert-able).
4. A short retrospective paragraph appended to this roadmap ("what landed, what deferred, server coupling status").

---

## Status log

| Date | Phase | Event |
|------|-------|-------|
| 2026-04-24 | Roadmap | Created. Calls hardening plan drafted. |
| _(append below as phases land)_ | | |
