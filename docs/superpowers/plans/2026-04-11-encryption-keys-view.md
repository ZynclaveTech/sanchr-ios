# EncryptionKeysView Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make EncryptionKeysView fully functional by adding three missing protocol methods to `KeyManagerProtocol`/`SignalKeyManager`, wiring all stub buttons, and replacing hardcoded metadata with real values.

**Architecture:** `KeyManagerProtocol` gains `fetchPreKeyCount()`, `signedPreKeyCreatedAt()`, and `resetIdentityKeys()`; `SignalKeyManager` implements them using existing gRPC and local store APIs. `EncryptionKeysView` replaces hardcoded values + empty closures with real async calls, alert flows, and a `ShareSheet`. Two files change.

**Tech Stack:** SwiftUI, LibSignalClient, gRPC (`Vync_Keys_KeyServiceAsyncClientProtocol`), `SanchrSignedPreKeyStore`, `UIActivityViewController`, Xcode scheme `Sanchr`

---

## File Map

| File | Role |
|------|------|
| `Sanchr-IOS/SanchrShared/Crypto/KeyManager.swift` | Add 3 methods to `KeyManagerProtocol` + implement in `SignalKeyManager` |
| `Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift` | Add state, real `.task {}`, wire Share/Reset/Regenerate buttons, disable Scan |

---

### Task 1: Add Protocol Methods + Implementations to KeyManager

**Files:**
- Modify: `Sanchr-IOS/SanchrShared/Crypto/KeyManager.swift`

- [ ] **Step 1: Re-read the file**

```bash
wc -l /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/SanchrShared/Crypto/KeyManager.swift
```

Expected: ~292 lines.

- [ ] **Step 2: Add three methods to `KeyManagerProtocol`**

Find the closing of the protocol (the last method before `var hasIdentityKeys: Bool { get }`):

Old:
```swift
    /// Returns `true` if identity keys have been generated for this device.
    var hasIdentityKeys: Bool { get }
}
```

New:
```swift
    /// Returns the number of one-time pre-keys currently registered on the server.
    func fetchPreKeyCount() async throws -> Int

    /// Returns the creation timestamp of the current signed pre-key, or nil if none exists.
    func signedPreKeyCreatedAt() throws -> Date?

    /// Regenerates the identity key pair and re-uploads the full key bundle.
    /// ⚠️ Destructive: invalidates all existing sessions and changes the safety number.
    func resetIdentityKeys() async throws

    /// Returns `true` if identity keys have been generated for this device.
    var hasIdentityKeys: Bool { get }
}
```

- [ ] **Step 3: Implement `fetchPreKeyCount()` in `SignalKeyManager`**

Find the end of `checkAndReplenishPreKeys` (line ~183):

```swift
    public func checkAndReplenishPreKeys(threshold: Int = 25) async throws {
        let request = Vync_Keys_GetPreKeyCountRequest()
        let response = try await keyService.getPreKeyCount(request)

        if response.count < Int32(threshold) {
            SanchrLogger.crypto.info(
                "Server pre-key count (\(response.count)) below threshold (\(threshold)), replenishing"
            )
            try await replenishPreKeys()
        } else {
            SanchrLogger.crypto.info("Server pre-key count (\(response.count)) is sufficient")
        }
    }
```

Add the new implementation immediately after the closing brace of `checkAndReplenishPreKeys`:

```swift
    public func fetchPreKeyCount() async throws -> Int {
        let request = Vync_Keys_GetPreKeyCountRequest()
        let response = try await keyService.getPreKeyCount(request)
        return Int(response.count)
    }

    public func signedPreKeyCreatedAt() throws -> Date? {
        let id = store.signedPreKeyStore.currentSignedPreKeyId
        guard id != 0 else { return nil }
        let record = try store.signedPreKeyStore.loadSignedPreKey(id: id, context: NullContext())
        // timestamp is stored as milliseconds since epoch (UInt64)
        return Date(timeIntervalSince1970: Double(record.timestamp) / 1000.0)
    }

    public func resetIdentityKeys() async throws {
        _ = try store.identityStore.generateAndStoreIdentity()
        try await uploadInitialKeyBundle()
        SanchrLogger.crypto.info("Identity keys reset and new bundle uploaded")
    }
```

- [ ] **Step 4: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Verify the three new methods are present**

```bash
grep -n "fetchPreKeyCount\|signedPreKeyCreatedAt\|resetIdentityKeys" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/SanchrShared/Crypto/KeyManager.swift
```

Expected: 6 hits — 1 protocol declaration + 1 implementation for each of the three methods.

- [ ] **Step 6: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Sanchr-IOS/SanchrShared/Crypto/KeyManager.swift && \
git commit -m "$(cat <<'EOF'
feat(crypto): add fetchPreKeyCount, signedPreKeyCreatedAt, resetIdentityKeys to KeyManagerProtocol

Exposes real server pre-key count, signed pre-key creation timestamp, and
destructive identity reset to callers. Implementations reuse existing gRPC
endpoints and local store APIs.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Wire EncryptionKeysView — State and Real Metadata

**Files:**
- Modify: `Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift`

- [ ] **Step 1: Re-read the file**

```bash
wc -l /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift
```

Expected: ~215 lines.

- [ ] **Step 2: Add new `@State` properties**

Find the existing state block at the top of the struct:

Old:
```swift
    @State private var identityKeyFingerprint: String = "Loading..."
    @State private var preKeyCount: Int = 0
    @State private var signedPreKeyAge: String = "Unknown"
    @State private var copiedToClipboard = false
```

New:
```swift
    @State private var identityKeyFingerprint: String = "Loading..."
    @State private var preKeyCount: Int? = nil
    @State private var signedPreKeyAge: String = ""
    @State private var copiedToClipboard = false
    @State private var isLoadingMetadata = false
    @State private var showingShareSheet = false
    @State private var showingResetAlert = false
    @State private var isResettingKeys = false
    @State private var resetError: String? = nil
```

- [ ] **Step 3: Replace `loadKeyInfo()` with real async calls**

Find the entire `loadKeyInfo()` function:

Old:
```swift
    private func loadKeyInfo() async {
        if container.keyManager.hasIdentityKeys,
            let identity = try? container.keyManager.generateIdentityIfNeeded()
        {
            let pubKeyBytes = identity.identityKey.publicKey.serialize()
            let hex = pubKeyBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            identityKeyFingerprint = hex
        } else {
            identityKeyFingerprint = "No identity key generated"
        }

        // Pre-key count would come from the signal store
        preKeyCount = 100
        signedPreKeyAge = "2 days"
    }
```

New:
```swift
    private func loadKeyInfo() async {
        if container.keyManager.hasIdentityKeys,
            let identity = try? container.keyManager.generateIdentityIfNeeded()
        {
            let pubKeyBytes = identity.identityKey.publicKey.serialize()
            let hex = pubKeyBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            identityKeyFingerprint = hex
        } else {
            identityKeyFingerprint = "No identity key generated"
        }

        isLoadingMetadata = true
        defer { isLoadingMetadata = false }

        if let count = try? await container.keyManager.fetchPreKeyCount() {
            preKeyCount = count
        }

        if let date = try? container.keyManager.signedPreKeyCreatedAt() {
            let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
            signedPreKeyAge = days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s") ago"
        } else {
            signedPreKeyAge = "Unknown"
        }
    }
```

- [ ] **Step 4: Update `preKeyCount` display to handle `nil`**

The "Remaining" row reads `\(preKeyCount)`. After the `@State` type change to `Int?`, update the display:

Find:
```swift
                    Text("\(preKeyCount)")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(
                            preKeyCount < 10
                                ? .sanchrError
                                : preKeyCount < 50
                                    ? .sanchrWarning : Color.sanchrTextSecondary(colorScheme)
                        )
```

Replace with:
```swift
                    Text(preKeyCount.map { "\($0)" } ?? "—")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(
                            preKeyCount.map { $0 < 10 } == true
                                ? .sanchrError
                                : preKeyCount.map { $0 < 50 } == true
                                    ? .sanchrWarning : Color.sanchrTextSecondary(colorScheme)
                        )
```

Also update the `if preKeyCount < 10` low-supply warning:

Old:
```swift
                if preKeyCount < 10 {
```

New:
```swift
                if preKeyCount.map({ $0 < 10 }) == true {
```

- [ ] **Step 5: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift && \
git commit -m "$(cat <<'EOF'
feat(encryption-keys): replace hardcoded metadata with real pre-key count and age

loadKeyInfo() now calls fetchPreKeyCount() and signedPreKeyCreatedAt() from
KeyManagerProtocol. preKeyCount is Int? to distinguish zero from not-yet-loaded.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire Share Button, Regenerate Button, and Disable Scan

**Files:**
- Modify: `Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift`

- [ ] **Step 1: Re-read the file**

```bash
wc -l /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift
```

Confirm the file is the state left by Task 2.

- [ ] **Step 2: Wire the Share button**

Find the Share button (the empty-closure one, not the Copy button):

Old:
```swift
                        Button {
                            // Share via QR code or text
                        } label: {
                            Label("Share", systemImage: "qrcode")
                                .font(SanchrTypography.caption)
                        }
```

New:
```swift
                        Button {
                            showingShareSheet = true
                        } label: {
                            Label("Share", systemImage: "qrcode")
                                .font(SanchrTypography.caption)
                        }
```

- [ ] **Step 3: Attach the share sheet to the Identity Key section**

Find the section closing line immediately after the Share button's enclosing `HStack`:

```swift
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
```

The first such closing (after the Identity Key VStack → HStack → Copy + Share buttons) is the one to modify. Replace with:

```swift
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: [identityKeyFingerprint])
            }
```

- [ ] **Step 4: Wire the Regenerate Pre-Keys button**

Find the stub:

Old:
```swift
    private func regeneratePreKeys() async {
        // Trigger pre-key regeneration via the key manager
        SanchrLogger.crypto.info("Regenerating one-time pre-keys")
    }
```

New:
```swift
    private func regeneratePreKeys() async {
        do {
            try await container.keyManager.replenishPreKeys()
            if let count = try? await container.keyManager.fetchPreKeyCount() {
                preKeyCount = count
            }
            SanchrLogger.crypto.info("One-time pre-keys replenished")
        } catch {
            SanchrLogger.crypto.error("Failed to replenish pre-keys: \(error)")
        }
    }
```

- [ ] **Step 5: Disable the Scan Safety Number button**

Find the Scan Safety Number button:

Old:
```swift
                    Button {
                        // Open safety number scanner
                    } label: {
                        HStack(spacing: SanchrSpacing.xs) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title3)
                            Text("Scan Safety Number")
                                .font(SanchrTypography.body)
                        }
                        .foregroundColor(.sanchrPrimary)
                    }
```

New:
```swift
                    Button {
                        // no-op — safety number verification is per-conversation
                    } label: {
                        HStack(spacing: SanchrSpacing.xs) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title3)
                            Text("Scan Safety Number")
                                .font(SanchrTypography.body)
                        }
                        .foregroundColor(.sanchrPrimary)
                    }
                    .disabled(true)
                    .opacity(0.5)

                    Text("Open a conversation to verify safety numbers with a specific contact.")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
```

- [ ] **Step 6: Add `ShareSheet` private struct before the closing brace of `EncryptionKeysView`**

Find:
```swift
    private func regeneratePreKeys() async {
```

Add this block immediately before it:
```swift
    // MARK: - ShareSheet

    private struct ShareSheet: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
    }

```

- [ ] **Step 7: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift && \
git commit -m "$(cat <<'EOF'
feat(encryption-keys): wire Share button, Regenerate pre-keys, disable Scan

Share button opens UIActivityViewController with fingerprint text.
Regenerate pre-keys calls replenishPreKeys() and refreshes count.
Scan Safety Number is disabled with explanatory text.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Wire Reset Keys Button with Destructive Alert

**Files:**
- Modify: `Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift`

- [ ] **Step 1: Re-read the file**

```bash
wc -l /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift
```

Confirm the file is the state left by Task 3.

- [ ] **Step 2: Replace the stub Reset Keys button with the full alert flow**

Find the Reset Keys section:

Old:
```swift
            // MARK: - Reset Keys (Dangerous)
            Section {
                Button(role: .destructive) {
                    // Reset all encryption keys
                } label: {
                    Text("Reset encryption keys")
                }

                Text(
                    "This will end all active encrypted sessions. You will need to verify your identity with all contacts again."
                )
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
```

New:
```swift
            // MARK: - Reset Keys (Dangerous)
            Section {
                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    Text(isResettingKeys ? "Resetting…" : "Reset encryption keys")
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
                    Text(
                        "This will generate new encryption keys and invalidate all existing sessions. All contacts will see a safety number change. This cannot be undone."
                    )
                }
                .alert("Reset Failed", isPresented: Binding(
                    get: { resetError != nil },
                    set: { if !$0 { resetError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(resetError ?? "")
                }

                Text(
                    "This will end all active encrypted sessions. You will need to verify your identity with all contacts again."
                )
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verify all stub closures are gone**

```bash
grep -n "// Reset all\|// Share via\|// Open safety\|// Trigger pre-key" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift
```

Expected: 0 hits. (All stubs replaced.)

- [ ] **Step 5: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && \
git add Sanchr-IOS/Features/Settings/Presentation/EncryptionKeysView.swift && \
git commit -m "$(cat <<'EOF'
feat(encryption-keys): wire Reset Keys with destructive alert and error handling

Reset Keys button sets showingResetAlert, which presents a two-tap
destructive flow. resetIdentityKeys() failure surfaces in a second alert.
Button is disabled while operation is in progress.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
1. ✅ `preKeyCount` shows real server count — Task 2 Step 3 calls `fetchPreKeyCount()`
2. ✅ `signedPreKeyAge` shows real age — Task 2 Step 3 calls `signedPreKeyCreatedAt()` + formats with `Calendar`
3. ✅ Share button opens system share sheet with fingerprint — Task 3 Steps 2–3 + `ShareSheet` struct
4. ✅ Reset Keys regenerates identity after destructive-action confirmation — Task 4 Step 2
5. ✅ Scan Safety Number disabled with accurate label — Task 3 Step 5
6. ✅ Regenerate Pre-Keys calls `replenishPreKeys()` and refreshes count — Task 3 Step 4

**Placeholder scan:** No TBDs. All code blocks are complete and exact.

**Type consistency:**
- `preKeyCount: Int?` — declared in Task 2 Step 2, used in Steps 4 and across Tasks 3–4
- `showingShareSheet: Bool`, `showingResetAlert: Bool`, `isResettingKeys: Bool`, `resetError: String?` — declared in Task 2 Step 2, used in Tasks 3–4
- `fetchPreKeyCount() async throws -> Int` — defined in Task 1 Step 2, called in Tasks 2 and 3
- `signedPreKeyCreatedAt() throws -> Date?` — defined in Task 1 Step 2, called in Task 2
- `resetIdentityKeys() async throws` — defined in Task 1 Step 2, called in Task 4
- `replenishPreKeys() async throws` — already on the protocol, called in Task 3 Step 4
- `ShareSheet(items: [identityKeyFingerprint])` — `items: [Any]`, `identityKeyFingerprint: String` — compatible ✅
