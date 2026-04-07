# SanchrShareExtension

iOS Share Extension that lets users send content into Sanchr from any host
app (Safari, Photos, Files, Messages, third-party apps). Runs the full
end-to-end-encrypted send pipeline in-process — no IPC to the main app, no
background relay.

## Architecture

```
Host app ──► ShareViewController
                │
                ▼
        ShareRootView (SwiftUI)
                │
                ├─► ShareUnlockView   (biometric/passcode gate)
                ├─► ShareChatPickerView   (multi-select)
                ├─► ShareComposerView     (caption + preview)
                └─► ShareProgressSheet    (per-recipient fan-out)
                          │
                          ▼
                ShareSendCoordinator (actor, extension-only)
                          │
                          ├─ flattens SharePayload → [ShareSendUnit]
                          ├─ builds self-contained dependency stack
                          └─ delegates to
                                     │
                                     ▼
                      ShareSendDispatcher  (actor, SanchrShared)
                                     │
                                     └─ fans out units to every
                                        recipient via a structured
                                        task group; reports per-
                                        recipient progress through a
                                        @Sendable closure
```

### Why two coordinators?

The share extension is an `app-extension` binary, which cannot be loaded
into a unit-test host. To keep the multi-recipient fan-out logic
unit-testable, the interesting concurrency lives in
`SanchrShared/Share/ShareSendDispatcher.swift` behind a narrow
`ShareMessageSending` test seam. The extension-side
`ShareSendCoordinator` owns the pieces that can't leave the extension:
payload flattening (depends on the extension-only `SharePayload`) and
the dependency-stack bootstrap.

### Payload pipeline

1. `ShareViewController` receives the `NSExtensionItem`s from the host.
2. `SharePayloadLoader` normalises every attachment into a `SharePayload`
   (text/url/image/video/audio/file/multi). File-based payloads are copied
   into `AppGroup.mediaCacheURL` so the URLs remain valid after
   `loadFileRepresentation`'s completion handler returns.
3. `ShareRootView` walks the user through unlock → picker → composer →
   progress sheet.
4. `ShareSendCoordinator.send(...)` flattens the payload, builds the
   dependency stack once per batch, and hands the units to
   `ShareSendDispatcher`.

## Dependency stack (built per send batch)

The share extension has no `DependencyContainer`, so the coordinator
constructs its own minimal stack from extension-safe primitives:

| Dependency                       | Source                                            |
| -------------------------------- | ------------------------------------------------- |
| `KeychainService`                | shared `keychain-access-groups` entitlement       |
| `SecureStorage`                  | wraps the shared keychain                         |
| `MediaChainState`                | seed read from shared keychain                    |
| `LocalDatabase`                  | `LocalDatabase.openForExtension()` (App Group)    |
| `SanchrGRPCClient`               | `AppConfiguration.current`                        |
| `SanchrSignalStore` / managers   | pinned to the user in `SessionSnapshot`           |
| `MediaUploadManager`             | full encrypt-and-upload pipeline                  |
| `DefaultEncryptedMessageSendingClient` | uses `OneShotAuthRetrying`                  |
| `FileCoordinatorLock`            | cross-process Signal ratchet lock                 |
| `MessageSender`                  | final wiring                                      |

## Entitlements

Both `Sanchr` (main app) and `SanchrShareExtension` require matching
capabilities. If your developer profile doesn't have them, the extension
will fail to open the shared database / keychain and the user will see a
"Couldn't load chats" or "Open Sanchr once to finish setup" error.

- **App Group:** `group.io.sanchr.shared`
  - Used for the shared SQLite database and the media cache directory.
- **Keychain Sharing:** `io.sanchr.shared`
  - Used for `SessionSnapshot`, identity keys, and the media access
    secret.

The entitlements files are tracked at:

- `Sanchr.entitlements`
- `SanchrShareExtension/SanchrShareExtension.entitlements`

## Migration from pre-App-Group installs

On first launch after upgrading, `SanchrAppDelegate.didFinishLaunching`
calls `AppGroupMigration.runIfNeeded()` to copy the legacy
`Library/Application Support/Sanchr/db.sqlite` (+ WAL/SHM) into the App
Group container before `DependencyContainer.localDatabase` opens it. The
migration is idempotent, non-throwing, and a no-op on clean installs.
Until the main app has been launched once post-upgrade,
`ShareViewController` gates on `AppGroupMigration.isComplete` and shows
the "Open Sanchr once to finish setup" state.

## Known limitations

- **No access-token refresh.** The extension uses `OneShotAuthRetrying`:
  if the access token is expired when the send runs, every recipient
  fails with a session-expired message. Users have to re-open the main
  app to refresh, then retry.
- **Media pipeline runs in-process.** Uploads are not handed off to
  `URLSession` background configuration; if the user kills the extension
  mid-upload the partial upload is abandoned. Uploaded chunks are not
  resumed on retry.
- **Hard 100 MB per-attachment / per-batch cap.** Enforced in
  `SharePayload.maxSizeBytes` before the picker even opens.
- **Sequential Signal ratchet under `FileCoordinatorLock`.** Uploads run
  outside the lock, but the ratchet + gRPC `sendMessage` are serialized
  across all processes sharing the lock. Parallel recipient sends from
  the dispatcher will queue at the lock boundary — this is intentional
  to preserve Signal session state integrity.
- **User must be signed in.** The extension reads the current user from
  `SessionSnapshot`; if the snapshot is missing the extension surfaces a
  bootstrap error and every recipient fails.
- **No reactions, edits, or replies** from the share sheet — just new
  outbound messages.

## Development

After pulling any change that touches the extension target or
`project.yml`, regenerate the Xcode project:

```bash
cd ios/Sanchr-iOS
xcodegen generate
```

Run the unit tests (the multi-recipient fan-out coverage lives in the
main `SanchrTests` target, not in an extension-specific target):

```bash
xcodebuild test -scheme Sanchr \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -only-testing:SanchrTests/MultiRecipientSendTests
```

See [`ACCEPTANCE.md`](./ACCEPTANCE.md) for the manual smoke-test
checklist.
