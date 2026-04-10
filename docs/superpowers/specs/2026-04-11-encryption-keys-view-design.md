# EncryptionKeysView Completion Design

**Date:** 2026-04-11
**Status:** Approved

## Problem

`EncryptionKeysView` (reached via Chat Settings → Security Code) displays the user's encryption key fingerprint and offers three action buttons. None of the buttons work:

- **Share** — empty closure, nothing happens
- **Scan Safety Number** — empty closure, nothing happens
- **Reset Keys** — empty closure, nothing happens

Additionally, two metadata values displayed in the view are hardcoded placeholders:
- `preKeyCount = 100` — hardcoded integer
- `signedPreKeyAge = "2 days"` — hardcoded string

The identity key fingerprint itself **is** loaded correctly from `keyManager`.

## Goals

1. `preKeyCount` displays the real count of one-time pre-keys remaining on the server.
2. `signedPreKeyAge` displays the real age of the current signed pre-key.
3. **Share** button opens a system share sheet with the identity key fingerprint.
4. **Reset Keys** button regenerates the identity key pair after a destructive-action confirmation.
5. **Scan Safety Number** is disabled with an accurate label explaining where to find it.

## Non-Goals

- Implementing per-conversation Safety Number QR scanning (that feature belongs in a conversation detail view, not the global key management screen).
- Changing the identity key fingerprint display format.
- Modifying key upload scheduling or replenishment logic.

## Architecture

Two files change. `KeyManagerProtocol` gains three new methods; `EncryptionKeysView` calls them.

```
KeyManagerProtocol (SanchrShared/Crypto/KeyManager.swift)
  + func fetchPreKeyCount() async throws -> Int
  + func signedPreKeyCreatedAt() throws -> Date?
  + func resetIdentityKeys() async throws

SignalKeyManager (concrete implementation, same file)
  fetchPreKeyCount()      → calls existing keyService.getPreKeyCount() gRPC endpoint
  signedPreKeyCreatedAt() → queries signedPreKeyStore.loadSignedPreKey() for creation date
  resetIdentityKeys()     → generateIdentityIfNeeded() with force flag + uploadInitialKeyBundle()

EncryptionKeysView
  .task {}           → await keyManager.fetchPreKeyCount()
                     → keyManager.signedPreKeyCreatedAt() → formatted age string
  Share button       → showingShareSheet = true → ShareSheet(items: [fingerprint])
  Reset Keys button  → showingResetAlert = true → destructive alert → keyManager.resetIdentityKeys()
  Scan button        → .disabled(true), subtitle "Open a conversation to verify"
```

## Component Specification

### `KeyManager.swift` — Protocol additions

```swift
// Add to KeyManagerProtocol:

/// Returns the number of one-time pre-keys currently registered on the server.
func fetchPreKeyCount() async throws -> Int

/// Returns the creation date of the current signed pre-key, or nil if unavailable.
func signedPreKeyCreatedAt() throws -> Date?

/// Regenerates the identity key pair and re-uploads the full key bundle.
/// ⚠️ Destructive: invalidates all existing sessions and changes the safety number.
func resetIdentityKeys() async throws
```

### `KeyManager.swift` — `SignalKeyManager` implementations

**`fetchPreKeyCount()`:**
```swift
func fetchPreKeyCount() async throws -> Int {
    return try await keyService.getPreKeyCount()
}
```
`keyService.getPreKeyCount()` is already called internally by `checkAndReplenishPreKeys`; this exposes it directly.

**`signedPreKeyCreatedAt()`:**
```swift
func signedPreKeyCreatedAt() throws -> Date? {
    guard let record = try signedPreKeyStore.loadCurrentSignedPreKey() else { return nil }
    return record.createdAt
}
```
`signedPreKeyStore` is already held by `SignalKeyManager`; `loadCurrentSignedPreKey()` (or equivalent) returns the active record with its timestamp.

**`resetIdentityKeys()`:**
```swift
func resetIdentityKeys() async throws {
    try generateNewIdentityKeyPair()   // overwrites persisted identity
    try await uploadInitialKeyBundle() // registers new keys with server
}
```
`uploadInitialKeyBundle()` already exists and handles the full registration flow.

### `EncryptionKeysView.swift` — State additions

```swift
@State private var preKeyCount: Int? = nil
@State private var signedPreKeyAge: String = ""
@State private var isLoadingMetadata = false
@State private var showingShareSheet = false
@State private var showingResetAlert = false
@State private var isResettingKeys = false
@State private var resetError: String? = nil
```

### `EncryptionKeysView.swift` — `.task {}` update

Replace hardcoded assignments with real calls:

```swift
.task {
    isLoadingMetadata = true
    defer { isLoadingMetadata = false }

    // Real pre-key count
    if let count = try? await container.keyManager.fetchPreKeyCount() {
        preKeyCount = count
    }

    // Real signed pre-key age
    if let date = try? container.keyManager.signedPreKeyCreatedAt() {
        let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
        signedPreKeyAge = days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
```

### `EncryptionKeysView.swift` — Share button

```swift
Button {
    showingShareSheet = true
} label: {
    // existing label unchanged
}
.sheet(isPresented: $showingShareSheet) {
    ShareSheet(items: [fingerprint])
}
```

`ShareSheet` is a thin `UIViewControllerRepresentable` wrapping `UIActivityViewController`:

```swift
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
```

### `EncryptionKeysView.swift` — Reset Keys button

```swift
Button(role: .destructive) {
    showingResetAlert = true
} label: {
    // existing label unchanged
}
.disabled(isResettingKeys)
.alert("Reset Encryption Keys?", isPresented: $showingResetAlert) {
    Button("Reset", role: .destructive) {
        Task {
            isResettingKeys = true
            do {
                try await container.keyManager.resetIdentityKeys()
            } catch {
                resetError = error.localizedDescription
            }
            isResettingKeys = false
        }
    }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("This will generate new encryption keys and invalidate all existing sessions. All contacts will see a safety number change. This cannot be undone.")
}
.alert("Reset Failed", isPresented: Binding(
    get: { resetError != nil },
    set: { if !$0 { resetError = nil } }
)) {
    Button("OK", role: .cancel) {}
} message: {
    Text(resetError ?? "")
}
```

### `EncryptionKeysView.swift` — Scan Safety Number button

Disable the button and update its subtitle:

```swift
Button {
    // no-op; disabled
} label: {
    // existing chevronRow label, but subtitle changed:
    chevronRow(
        icon: "qrcode.viewfinder",
        title: "Scan Safety Number",
        subtitle: "Open a conversation to verify"  // was: "Verify with a contact"
    )
}
.disabled(true)
.opacity(0.5)
```

## Data Flow

```
View appears:
  .task {} fires
    → fetchPreKeyCount() → gRPC getPreKeyCount → returns 47
    → signedPreKeyCreatedAt() → store query → returns Date 3 days ago
    → UI shows "47 pre-keys" and "3 days ago"

Share tapped:
  → showingShareSheet = true
  → ShareSheet presents with fingerprint string
  → user copies / sends via Messages / AirDrop / etc.

Reset tapped:
  → showingResetAlert = true
  → user reads warning, taps "Reset"
  → isResettingKeys = true (button disabled)
  → generateNewIdentityKeyPair() → persisted locally
  → uploadInitialKeyBundle() → server registers new keys
  → isResettingKeys = false
  → all existing sessions invalidated; contacts see safety number change
```

## Error Handling

- **`fetchPreKeyCount()` fails**: `preKeyCount` stays `nil`; UI shows "—" or hides the row. Silent failure (non-critical metadata).
- **`signedPreKeyCreatedAt()` fails**: `signedPreKeyAge` stays empty; UI shows "Unknown". Silent failure.
- **`resetIdentityKeys()` fails**: `resetError` is set; a second alert shows the error. `isResettingKeys` reset to `false` so the button re-enables.
- **Network offline during reset**: the underlying `uploadInitialKeyBundle()` throws; caught and shown via `resetError` alert.

## Security Considerations

- The Share sheet shares only the **fingerprint string** (human-readable hex/emoji safety number), not the raw key bytes.
- Reset Keys requires two explicit taps (button → destructive alert → "Reset" button). Cannot be triggered accidentally.
- `resetIdentityKeys()` must not be callable while `isResettingKeys = true` (button disabled during the operation).
- The "Scan Safety Number" feature is **not** implemented here because it is fundamentally a per-contact verification flow. Implementing it globally (without a specific contact's public key to compare against) would produce a misleading or non-functional UX. It belongs in a future conversation detail action sheet.

## Testing

1. Build succeeds.
2. Open Encryption Keys view → `preKeyCount` shows a real integer (not 100), `signedPreKeyAge` shows a real date string (not "2 days").
3. Tap Share → system share sheet appears with the fingerprint text.
4. Tap Reset → alert appears with warning text → tap Cancel → nothing changes.
5. Tap Reset → alert appears → tap Reset → keys regenerate → view re-displays (no crash).
6. Scan Safety Number button is visually dimmed and does not respond to taps.

## Files Changed

| File | Change |
|------|--------|
| `SanchrShared/Crypto/KeyManager.swift` | Add `fetchPreKeyCount()`, `signedPreKeyCreatedAt()`, `resetIdentityKeys()` to protocol and `SignalKeyManager` |
| `Features/Settings/Presentation/EncryptionKeysView.swift` | Add state, real `.task {}`, `ShareSheet`, Reset alert, disable Scan button |
