# Chat Settings Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove duplicated privacy controls from ChatSettingsView, fix a mislabelled section, delete dead code, apply `iconTile`'s ignored parameters, and strip all static `E5E7EB` borders for visual consistency with the already-cleaned AppearanceView.

**Architecture:** All changes are confined to a single file — `ChatSettingsView.swift`. They are purely structural edits to a SwiftUI `View`; no new types, no ViewModel changes, no backend calls.

**Tech Stack:** SwiftUI, Xcode 16, scheme `Sanchr`

---

## File Map

| File | Action |
|------|--------|
| `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift` | Modify — all five fixes below |

---

### Task 1: Remove `privacyControlsSection` (duplicate of PrivacyView)

Read Receipts, Online Status, and Typing Indicators are already present in **PrivacyView** wired to its own `SettingsViewModel` instance. Having them again in ChatSettingsView on a **separate** ViewModel instance means the two screens can silently disagree about the current setting.

**Files:**
- Modify: `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift`

- [ ] **Step 1: Re-read the file before editing**

```bash
# just confirm line counts haven't shifted
wc -l /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift
```

Expected: ~675 lines.

- [ ] **Step 2: Remove `privacyControlsSection` from `body`**

In `body`, remove the `privacyControlsSection` line so `body` reads:

```swift
VStack(spacing: 18) {
    mediaDownloadSection
    encryptionSection
    backupSection
    disappearingSection
}
```

Old string to replace:

```swift
            VStack(spacing: 18) {
                privacyControlsSection
                mediaDownloadSection
                encryptionSection
                backupSection
                disappearingSection
            }
```

New string:

```swift
            VStack(spacing: 18) {
                mediaDownloadSection
                encryptionSection
                backupSection
                disappearingSection
            }
```

- [ ] **Step 3: Delete the `privacyControlsSection` computed property**

Remove this entire block (the `privacyControlsSection` computed property, lines 106–158 in the original file):

```swift
    private var privacyControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Privacy Controls")

            VStack(spacing: 0) {
                toggleRow(
                    icon: "checkmark.message.fill",
                    tint: SanchrColors.primary,
                    background: Color(hex: 0xEEF2FF),
                    title: "Read Receipts",
                    subtitle: "Show when you've read messages",
                    isOn: $viewModel.readReceipts
                ) {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "dot.radiowaves.left.and.right",
                    tint: SanchrColors.accent,
                    background: Color(hex: 0xECFEFF),
                    title: "Online Status",
                    subtitle: "Let others see when you're active",
                    isOn: $viewModel.onlineStatusVisible
                ) {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "keyboard.fill",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "Typing Indicators",
                    subtitle: "Show when you're typing",
                    isOn: $viewModel.typingIndicator
                ) {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
            }
        }
    }
```

- [ ] **Step 4: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr && \
git add ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift && \
git commit -m "$(cat <<'EOF'
feat(settings): remove duplicate privacy controls from ChatSettingsView

Read Receipts, Online Status, and Typing Indicators already live in
PrivacyView. A second copy on a separate ViewModel instance could drift
out of sync; remove the redundant section entirely.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Delete dead `selectionIndicator` helper

`selectionIndicator` was used exclusively by `bubbleSection`, which was removed in the previous session's cleanup. It is now unreachable.

**Files:**
- Modify: `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift`

- [ ] **Step 1: Re-read the file to confirm `selectionIndicator` has no remaining call sites**

```bash
grep -n "selectionIndicator" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift
```

Expected: only the function definition line, no call sites.

- [ ] **Step 2: Delete the `selectionIndicator` function**

Remove this entire function:

```swift
    private func selectionIndicator(isSelected: Bool) -> some View {
        Circle()
            .fill(isSelected ? SanchrColors.primary : .clear)
            .frame(width: 24, height: 24)
            .overlay {
                Circle()
                    .stroke(isSelected ? SanchrColors.primary : Color(hex: 0xD1D5DB), lineWidth: 2)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
            }
    }
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr && \
git add ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift && \
git commit -m "$(cat <<'EOF'
refactor(settings): delete dead selectionIndicator from ChatSettingsView

Used exclusively by bubbleSection which was removed in the previous
cleanup pass. Dead code deleted.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Fix `iconTile` — apply its `tint` and `background` parameters

`iconTile` accepts `tint: Color` and `background: Color` but silently ignores both, always rendering `SanchrExportColors.surfaceMuted` fill and `.sanchrPrimary` icon colour. Every call site passes distinct per-row colours that are then discarded.

**Files:**
- Modify: `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift`

- [ ] **Step 1: Replace the `iconTile` implementation**

Old:

```swift
    private func iconTile(systemName: String, tint: Color, background: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SanchrExportColors.surfaceMuted)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.sanchrPrimary)
            }
    }
```

New:

```swift
    private func iconTile(systemName: String, tint: Color, background: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(background)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
            }
    }
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr && \
git add ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift && \
git commit -m "$(cat <<'EOF'
fix(settings): apply iconTile tint/background parameters in ChatSettingsView

The helper accepted per-row colours but always rendered surfaceMuted +
sanchrPrimary, making the parameters dead. Wire them through so each row
gets its own colour identity.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Split `encryptionSection` → "Encryption & Security" + "Chat Behaviour"

The current `encryptionSection` groups three unrelated concerns under one label:
1. The E2E encryption status banner and Security Code link (legitimately security-related).
2. Enter Sends Message, Link Previews, Auto-save Received Media (device-local UX preferences — nothing to do with encryption).

Fix: rename the section, keep only the E2E banner + Security Code, and create a new "Chat Behaviour" section for the three device-local toggles.

**Files:**
- Modify: `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift`

- [ ] **Step 1: Replace the `encryptionSection` computed property**

Old (entire `encryptionSection` property):

```swift
    private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Encryption & Security")

            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [SanchrColors.primary, Color(hex: 0x4C1D95)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 112)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Image(systemName: "shield.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("End-to-End Encryption")
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(.white)
                                Text("All your messages and calls are secured. Only you and the recipient can read them.")
                                    .font(SanchrTypography.caption)
                                    .foregroundColor(.white.opacity(0.86))
                            }
                        }
                        .padding(.horizontal, 18)
                    }

                NavigationLink {
                    EncryptionKeysView()
                } label: {
                    chevronRow(
                        icon: "qrcode",
                        tint: SanchrColors.accent,
                        background: Color(hex: 0xECFEFF),
                        title: "Security Code",
                        subtitle: "Verify encryption keys"
                    )
                }
                .buttonStyle(.plain)

                VStack(spacing: 0) {
                    toggleRow(
                        icon: "paperplane.fill",
                        tint: Color(hex: 0x7C3AED),
                        background: Color(hex: 0xF3E8FF),
                        title: "Enter Sends Message",
                        subtitle: "Press return to send instantly",
                        isOn: $enterSendsMessage
                    ) {}

                    Divider()
                        .padding(.leading, 56)

                    toggleRow(
                        icon: "link",
                        tint: Color(hex: 0xCA8A04),
                        background: Color(hex: 0xFEF3C7),
                        title: "Link Previews",
                        subtitle: "Preview URLs inside chats",
                        isOn: $linkPreviews
                    ) {}

                    Divider()
                        .padding(.leading, 56)

                    toggleRow(
                        icon: "square.and.arrow.down.fill",
                        tint: Color(hex: 0x16A34A),
                        background: Color(hex: 0xDCFCE7),
                        title: "Auto-save Received Media",
                        subtitle: "Keep photos and videos offline",
                        isOn: $mediaAutoSave
                    ) {}
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                }
            }
        }
    }
```

New (two separate properties — replace the old one with both):

```swift
    private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Encryption & Security")

            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [SanchrColors.primary, Color(hex: 0x4C1D95)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 112)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Image(systemName: "shield.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("End-to-End Encryption")
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(.white)
                                Text("All your messages and calls are secured. Only you and the recipient can read them.")
                                    .font(SanchrTypography.caption)
                                    .foregroundColor(.white.opacity(0.86))
                            }
                        }
                        .padding(.horizontal, 18)
                    }

                NavigationLink {
                    EncryptionKeysView()
                } label: {
                    chevronRow(
                        icon: "qrcode",
                        tint: SanchrColors.accent,
                        background: Color(hex: 0xECFEFF),
                        title: "Security Code",
                        subtitle: "Verify encryption keys"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chatBehaviourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Chat Behaviour")

            VStack(spacing: 0) {
                toggleRow(
                    icon: "paperplane.fill",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "Enter Sends Message",
                    subtitle: "Press return to send instantly",
                    isOn: $enterSendsMessage
                ) {}

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "link",
                    tint: Color(hex: 0xCA8A04),
                    background: Color(hex: 0xFEF3C7),
                    title: "Link Previews",
                    subtitle: "Preview URLs inside chats",
                    isOn: $linkPreviews
                ) {}

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "square.and.arrow.down.fill",
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
                    title: "Auto-save Received Media",
                    subtitle: "Keep photos and videos offline",
                    isOn: $mediaAutoSave
                ) {}
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
```

- [ ] **Step 2: Add `chatBehaviourSection` to `body`**

In `body`, replace:

```swift
            VStack(spacing: 18) {
                mediaDownloadSection
                encryptionSection
                backupSection
                disappearingSection
            }
```

With:

```swift
            VStack(spacing: 18) {
                mediaDownloadSection
                encryptionSection
                chatBehaviourSection
                backupSection
                disappearingSection
            }
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr && \
git add ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift && \
git commit -m "$(cat <<'EOF'
refactor(settings): split encryptionSection into Encryption + Chat Behaviour

Enter Sends Message, Link Previews, and Auto-save Media are device-local
UX preferences unrelated to encryption. Move them to a new Chat Behaviour
section so both labels are accurate.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Remove static `E5E7EB` borders from `chevronRow` and backup cards

The previous session removed always-on borders from AppearanceView cards. The same pattern exists in ChatSettingsView: `chevronRow` and the two backup container cards all carry a `stroke(Color(hex: 0xE5E7EB), lineWidth: 1)` overlay that is never conditional — it shows even when nothing is selected. Remove all three.

**Files:**
- Modify: `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift`

- [ ] **Step 1: Remove the border overlay from `chevronRow`**

Old:

```swift
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
        }
    }
```

New:

```swift
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
```

- [ ] **Step 2: Remove the border overlay from the backup toggle card**

The backup toggle card (`HStack` containing the Chat Backup toggle) ends with:

```swift
                .padding(16)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                }
```

Remove the `.overlay` block, leaving:

```swift
                .padding(16)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
```

- [ ] **Step 3: Remove the border overlay from the backup actions group card**

The conditional `VStack` of backup actions (Back Up Now / Reveal Recovery Key / …) ends with:

```swift
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                    }
```

Remove the `.overlay` block, leaving:

```swift
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
```

- [ ] **Step 4: Verify no remaining `E5E7EB` references in the file**

```bash
grep -n "E5E7EB" \
  /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift
```

Expected: no output (zero matches).

- [ ] **Step 5: Build to confirm it compiles**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios && \
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr && \
git add ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift && \
git commit -m "$(cat <<'EOF'
fix(settings): remove static E5E7EB borders from ChatSettingsView cards

Matches the AppearanceView cleanup: always-on gray borders removed from
chevronRow and both backup container cards. No conditional border logic
was present so the overlays are deleted outright.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage check:**
1. ✅ Remove `privacyControlsSection` — Task 1
2. ✅ Delete dead `selectionIndicator` — Task 2
3. ✅ Fix `iconTile` parameters — Task 3
4. ✅ Split `encryptionSection` + add "Chat Behaviour" — Task 4
5. ✅ Remove static `E5E7EB` borders (`chevronRow` + two backup cards) — Task 5

**Placeholder scan:** No TBDs, no TODOs, no "implement later". Every step contains exact code.

**Type consistency:** All references to `encryptionSection`, `chatBehaviourSection`, `chevronRow`, `iconTile`, `selectionIndicator`, `privacyControlsSection` are consistent across tasks. `chatBehaviourSection` is introduced in Task 4 Step 1 and added to `body` in Task 4 Step 2 before any build is attempted.

**Scope check:** All five tasks target the same single file; they are independent enough to commit separately and each leaves the app in a buildable state.
