# Splash Screen Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-composed system-icon splash with the real `SanchrLogo` asset and a polished Fade & Scale entrance animation on an always-dark background.

**Architecture:** Single SwiftUI view rewrite. One `@State var appeared: Bool` drives all five animated elements via `.animation(_:value:)` with staggered delays. No new files, no new assets, no Xcode project changes.

**Tech Stack:** SwiftUI, `SanchrLogo` imageset (Assets.xcassets), existing `SanchrTypography` / `SanchrExportColors` design tokens, `Color(hex:)` extension (takes `Int`, e.g. `Color(hex: 0x08080E)`).

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `Sanchr-iOS/Features/Auth/Presentation/SplashView.swift` | Full rewrite — animated splash with logo |

---

### Task 1: Rewrite SplashView with logo and animation

**Files:**
- Modify: `Sanchr-iOS/Features/Auth/Presentation/SplashView.swift`

This is a pure UI task. There is no logic to unit-test; correctness is verified by building the app and inspecting the `#Preview`. Follow the steps below exactly.

---

- [ ] **Step 1: Read the current file before editing**

Confirm the file path and current contents before touching it:

```bash
cat Sanchr-iOS/Features/Auth/Presentation/SplashView.swift
```

Expected: you see the existing hand-composed icon with `bubble.left.fill` and a shield badge circle. No surprises — just confirming state.

---

- [ ] **Step 2: Replace SplashView.swift with the new implementation**

Overwrite the entire file with the following. Do not leave any of the old code.

```swift
import SwiftUI
import SanchrShared

/// Full-screen splash shown during app launch.
///
/// Animation sequence (all driven by `appeared`):
///   0.00 s — ambient glow fades in (0.60 s, easeOut)
///   0.10 s — logo scales up from 0.75× with spring overshoot (0.55 s)
///   0.50 s — wordmark fades up (0.40 s, easeOut)
///   0.65 s — tagline fades up (0.40 s, easeOut)
///   0.85 s — spinner + caption fade up (0.35 s, easeOut)
struct SplashView: View {

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Always-dark background — does not follow system appearance.
            Color(hex: 0x08080E)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Logo + ambient glow ──────────────────────────────────
                ZStack {
                    // Soft radial glow behind the logo
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.sanchrPrimary.opacity(0.18),
                                    Color.clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 90
                            )
                        )
                        .frame(width: 180, height: 180)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.60).delay(0.00), value: appeared)

                    // Real SanchrLogo asset — blends into dark bg via .screen
                    Image("SanchrLogo")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .blendMode(.screen)
                        .scaleEffect(appeared ? 1.0 : 0.75)
                        .opacity(appeared ? 1 : 0)
                        .animation(
                            .spring(response: 0.45, dampingFraction: 0.62)
                            .delay(0.10),
                            value: appeared
                        )
                }

                // ── Wordmark + tagline ───────────────────────────────────
                VStack(spacing: 8) {
                    Text("Sanchr")
                        .font(SanchrTypography.heroTitle)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .offset(y: appeared ? 0 : 10)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.40).delay(0.50), value: appeared)

                    Text("Encrypted. Synced. Secure.")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .offset(y: appeared ? 0 : 10)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.40).delay(0.65), value: appeared)
                }
                .padding(.top, 24)

                Spacer()

                // ── Loading indicator ────────────────────────────────────
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.sanchrPrimary)
                    Text("Initializing secure connection...")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
                .padding(.bottom, 60)
                .offset(y: appeared ? 0 : 10)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.35).delay(0.85), value: appeared)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            appeared = true
        }
    }
}

// MARK: - Preview

#Preview {
    SplashView()
}
```

---

- [ ] **Step 3: Verify the file was written correctly**

```bash
head -10 Sanchr-iOS/Features/Auth/Presentation/SplashView.swift
```

Expected first line: `import SwiftUI`  
Expected third line: `struct SplashView: View {` (after blank line)

Also confirm no old code remains:

```bash
grep -n "bubble.left\|RoundedRectangle\|shield.fill" Sanchr-iOS/Features/Auth/Presentation/SplashView.swift
```

Expected: **no output** (zero matches).

---

- [ ] **Step 4: Build the target to catch any compile errors**

```bash
xcodebuild \
  -workspace Sanchr-iOS/Sanchr.xcworkspace \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug \
  build 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: `** BUILD SUCCEEDED **` with no `error:` lines.

Common errors and fixes:
- `Cannot find 'SanchrTypography' in scope` → confirm `import SanchrShared` is present on line 2
- `Cannot find 'Color(hex:)' in scope` → the extension is in `SanchrShared`; `import SanchrShared` resolves it
- `No image named 'SanchrLogo'` → verify the asset exists: `ls Sanchr-iOS/Resources/Assets.xcassets/SanchrLogo.imageset/`

---

- [ ] **Step 5: Run the app in the simulator and verify the animation**

Launch in the simulator:

```bash
xcodebuild \
  -workspace Sanchr-iOS/Sanchr.xcworkspace \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug \
  build 2>&1 | tail -5
```

Then open the simulator and cold-launch Sanchr. Verify visually:

1. Background is near-black (not the system white/grey)
2. Subtle indigo glow appears first behind where the logo will land
3. Logo scales up from ~75% with a slight spring overshoot — it briefly overshoots 100% then settles
4. "Sanchr" wordmark fades up ~0.4 s after logo lands
5. Tagline fades up ~0.15 s after wordmark
6. Spinner + caption fade up last (~0.2 s after tagline)
7. No hard box, halo, or white rectangle visible around the logo

---

- [ ] **Step 6: Commit**

```bash
git add Sanchr-iOS/Features/Auth/Presentation/SplashView.swift
git commit -m "feat: animated splash screen with SanchrLogo and fade-scale entrance"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Task / step |
|---|---|
| Always-dark `#08080E` background | Step 2 — `Color(hex: 0x08080E).ignoresSafeArea()` |
| `Image("SanchrLogo")` at 96×96pt | Step 2 — `.frame(width: 96, height: 96)` |
| `.renderingMode(.original)` | Step 2 |
| `.blendMode(.screen)` | Step 2 |
| RadialGradient glow 180pt, opacity 0.18 | Step 2 — `Ellipse` with `RadialGradient` |
| Glow: 0.0 s delay, 0.60 s easeOut | Step 2 — `.animation(.easeOut(duration: 0.60).delay(0.00), ...)` |
| Logo: 0.10 s delay, 0.55 s spring(0.45, 0.62) | Step 2 — `.spring(response: 0.45, dampingFraction: 0.62).delay(0.10)` |
| Wordmark: 0.50 s delay, 0.40 s easeOut | Step 2 — `.animation(.easeOut(duration: 0.40).delay(0.50), ...)` |
| Tagline: 0.65 s delay, 0.40 s easeOut | Step 2 — `.animation(.easeOut(duration: 0.40).delay(0.65), ...)` |
| Spinner + caption: 0.85 s delay, 0.35 s easeOut | Step 2 — `.animation(.easeOut(duration: 0.35).delay(0.85), ...)` |
| Retain `ProgressView` + caption | Step 2 |
| Single file change only | Step 6 — only `SplashView.swift` committed |

**Placeholder scan:** No TBDs, TODOs, or vague instructions found.

**Type consistency:** `SanchrTypography.heroTitle`, `SanchrTypography.body`, `SanchrTypography.caption`, `SanchrExportColors.textPrimary`, `SanchrExportColors.textSecondary`, `.sanchrPrimary` — all match tokens used throughout the existing codebase (confirmed in current file and Colors.swift).
