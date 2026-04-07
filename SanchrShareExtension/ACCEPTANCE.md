# SanchrShareExtension — Manual Acceptance Checklist

Run this list before every release that touches the share extension. The
automated `MultiRecipientSendTests` cover the fan-out logic in isolation,
but the extension lifecycle (host-app hand-off, App Group data, lock
gate, extension memory limits) can only be validated on a real device or
simulator with the full host app installed.

Every section is independently checkable; failures should be filed as
blocking bugs on the release, not punted to "next sprint".

## Pre-flight

- [ ] Branch built and installed on a device/simulator where the main
      `Sanchr` app is also installed and **signed in** with a real
      account.
- [ ] Provisioning profile includes:
    - [ ] App Group `group.io.sanchr.shared` on both targets.
    - [ ] Keychain access group `io.sanchr.shared` on both targets.
- [ ] At least one existing 1:1 chat and one group chat are visible in
      the main app's chat list.
- [ ] The main app's database has been opened once post-install (so
      `AppGroupMigration.runIfNeeded()` has run and `isComplete == true`).

## Share text (Safari)

- [ ] In Safari, long-press a link → Share → Sanchr.
- [ ] Picker shows your chats with recents strip at top.
- [ ] Select **three** recipients (mix of 1:1 and group).
- [ ] Composer shows the URL in the preview and a caption field.
- [ ] Add a short caption → Send.
- [ ] Progress sheet shows three rows, each transitioning
      pending → sending → success, with a linear overall bar reaching
      100%.
- [ ] Open the main app. Each of the three chats shows a new outgoing
      message with the URL **and** the caption (caption on the first
      line, URL on the second).
- [ ] No duplicate messages, no stuck "pending" status, no crash logs.

## Share image (Photos)

- [ ] Photos → pick a ~5 MB JPEG → Share → Sanchr.
- [ ] Composer shows the image thumbnail.
- [ ] Add caption "hello" → Send to one recipient.
- [ ] Progress sheet runs to success.
- [ ] In the main app, the recipient's thread shows the image with the
      caption. Tapping the image opens it at full resolution.
- [ ] Re-open the share sheet with the same image → the extension does
      NOT hold a stale reference from the previous session (no crashes,
      no wrong thumbnail).

## Share large photo (~50 MB)

- [ ] From Photos/Files, pick a ~50 MB photo or screen recording.
- [ ] Composer thumbnail renders within ~2 s (no hang).
- [ ] Send to one recipient.
- [ ] Progress sheet shows the row stay in `sending` for the upload
      duration, then transition to success.
- [ ] The recipient receives the full-fidelity media.

## Enforce 100 MB cap

- [ ] From Files, pick an attachment **> 100 MB**.
- [ ] Extension shows the "too large" error state immediately; no send
      button; no progress sheet.

## Multi-attachment share

- [ ] From Photos, select **3 photos** at once → Share → Sanchr.
- [ ] Composer preview shows all three thumbnails.
- [ ] Add a caption → Send to two recipients.
- [ ] Progress sheet shows two recipient rows; each transitions to
      success after the three attachments complete in order.
- [ ] Both recipients receive three messages in the picked order, and
      the caption appears **only on the first attachment** (no caption
      duplication).

## Locked-app unlock gate

- [ ] In the main app, enable app lock (biometric + passcode).
- [ ] Lock the device, then re-open and leave Sanchr in the locked
      state.
- [ ] From Safari, Share → Sanchr.
- [ ] Extension shows `ShareUnlockView`, not the picker.
- [ ] Biometric prompt succeeds → picker appears.
- [ ] Cancelling biometric returns to unlock view; tapping Cancel on the
      extension dismisses cleanly.

## Mid-send failure (airplane mode)

- [ ] Start a send to **5 recipients** on Wi-Fi.
- [ ] As soon as the first row shows `sending`, flip airplane mode on.
- [ ] Progress sheet continues: some rows succeed (the ones whose send
      had already reached the gRPC layer), the rest surface failure rows
      with a human-readable reason. Overall bar still reaches 100%.
- [ ] No hang, no spinner-forever. Done button enables.

## Cancel mid-send

- [ ] Start a send to 3 recipients with a large media payload so it
      takes several seconds.
- [ ] During the progress sheet, swipe down to dismiss (should be
      **blocked** — the sheet uses `interactiveDismissDisabled`).
- [ ] Tap the host-app Cancel button to terminate the extension.
- [ ] Re-open the main app. No zombie outbound rows in `pending` state;
      any sends that hadn't flushed are either fully committed or cleanly
      absent.

## Send while the main app is foregrounded

- [ ] Leave the main Sanchr app open on a chat thread.
- [ ] From another app, share text to Sanchr → pick that same chat →
      Send.
- [ ] Main app's thread updates with the new message without requiring
      a pull-to-refresh (live realtime path, or next foreground sync
      tick, depending on realtime wiring).
- [ ] No Signal-ratchet desync errors in the main app's logs.

## Upgrade path (pre-App-Group install)

- [ ] Install a **pre-App-Group** build of Sanchr (the last commit
      before `AppGroupMigration` landed) and sign in.
- [ ] Send a few messages so the legacy DB has rows.
- [ ] Install this branch over the top (without deleting).
- [ ] Open the main app once. Logs show
      `AppGroupMigration v1: complete`.
- [ ] Chats and messages from before the upgrade are all visible.
- [ ] Share text from Safari → Sanchr → the picker shows the migrated
      chats and a send completes successfully.

## Extension memory pressure

- [ ] Share the largest allowed payload (just under 100 MB) to a
      single recipient.
- [ ] The extension does not exceed iOS's ~120 MB share-extension memory
      limit (no `com.apple.ExtensionFoundation` terminations in
      Console.app).

## Logging sanity

- [ ] `SanchrLogger.chat`, `SanchrLogger.persistence`, and
      `SanchrLogger.network` all surface extension-side events in
      Console.app, attributed to the `SanchrShareExtension` process.
- [ ] No access-token or plaintext-body strings leak into the logs.

---

**Sign-off:** tester name + date after the full list passes on the
target release candidate.
