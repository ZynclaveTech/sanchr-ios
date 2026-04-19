# Splash Screen Animation — Design Spec
**Date:** 2026-04-19
**Status:** Approved
**File scope:** `Sanchr-iOS/Features/Auth/Presentation/SplashView.swift` only

---

## Goal

Replace the current hand-composed system-icon splash with the real `SanchrLogo` asset, add a polished entrance animation, and ensure the logo blends seamlessly into the always-dark background.

---

## Background

Always `Color(hex: "#08080E")` applied with `.ignoresSafeArea()`.  
Does **not** follow system appearance — the splash is always dark to match the app icon.

`Color(hex:)` is already defined in the project's `Color+Extensions`; no new helper needed.

---

## Logo Treatment

- **Asset:** `Image("SanchrLogo")` — existing `@1x/2x/3x` imageset in `Assets.xcassets`. No new assets required.
- **Size:** `96 × 96 pt` frame.
- **Rendering:** `.renderingMode(.original)` — preserves brand colours.
- **Blend:** `.blendMode(.screen)` — dissolves dark pixels in the PNG into the background so no box, halo, or hard edge is visible.
- **Ambient glow:** A `RadialGradient` ellipse (`180 × 180 pt`, `Color.sanchrPrimary` at opacity `0.18` → transparent) layered *behind* the logo in a `ZStack`. This adds depth without visual noise.

---

## Animation

Driven by a single `@State var appeared: Bool = false` flipped in `.onAppear { appeared = true }`.  
All transitions use `withAnimation` with per-element delays via `.animation(_:value:)`.

| Element | Start state | End state | Delay | Duration | Curve |
|---|---|---|---|---|---|
| Ambient glow | `opacity(0)` | `opacity(1)` | 0.00 s | 0.60 s | `.easeOut` |
| Logo (`Image`) | `opacity(0)` + `scaleEffect(0.75)` | `opacity(1)` + `scaleEffect(1)` | 0.10 s | 0.55 s | `.spring(response: 0.45, dampingFraction: 0.62)` |
| Wordmark `"Sanchr"` | `opacity(0)` + `offset(y: 10)` | `opacity(1)` + `offset(y: 0)` | 0.50 s | 0.40 s | `.easeOut` |
| Tagline | `opacity(0)` + `offset(y: 10)` | `opacity(1)` + `offset(y: 0)` | 0.65 s | 0.40 s | `.easeOut` |
| Spinner + caption | `opacity(0)` + `offset(y: 10)` | `opacity(1)` + `offset(y: 0)` | 0.85 s | 0.35 s | `.easeOut` |

The spring overshoot on the logo (dampingFraction 0.62) gives a subtle bounce at the end of the scale — confident, not bouncy.

---

## Loading Indicator

Retain existing `ProgressView().tint(.sanchrPrimary)` and `"Initializing secure connection…"` caption. Only the entrance animation (fade-up) is new. No behavioural change.

---

## Layout Structure

```
ZStack (full-screen, bg = #08080E)
  VStack(spacing: 0)
    Spacer
    ZStack                          ← logo + glow
      RadialGradient ellipse (glow)
      Image("SanchrLogo")
        .blendMode(.screen)
    VStack(spacing: 8)              ← text block, mt 24
      Text("Sanchr")
      Text("Encrypted. Synced. Secure.")
    Spacer
    VStack(spacing: 12)             ← loader, pb 60
      ProgressView
      Text("Initializing secure connection...")
```

---

## Files Changed

| File | Change |
|---|---|
| `Features/Auth/Presentation/SplashView.swift` | Full rewrite — ~65 lines |

No new assets, no new helpers, no Xcode project changes required.

---

## Out of Scope

- Light mode splash variant
- Lottie or other external animation libraries
- Custom loading progress (real backend connection status)
- Any change to the 1.15 s display duration managed by `SanchrApp`
