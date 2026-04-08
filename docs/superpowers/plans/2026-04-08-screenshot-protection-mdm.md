# Screenshot Protection MDM Deployment Note

**Date:** 2026-04-08  
**Status:** Active guidance  
**Scope:** iOS client behavior and managed-device deployment expectations

## Summary

Sanchr has two privacy-enforcement tracks:

1. **Standard iOS installs**: the app can detect still screenshots after capture and can hide protected content during live capture such as screen recording, QuickTime mirroring, and AirPlay.
2. **Managed devices**: true OS-level screenshot blocking requires Apple MDM policy, not app code.

## Managed-device policy

- Use Apple Device Management `Restrictions` with `allowScreenShot = false`.
- This is the supported path for blocking screenshots and screen recording system-wide on supervised or managed devices.
- The app does not toggle this policy and does not own its lifecycle.

Reference: [Apple Device Management Restrictions](https://developer.apple.com/documentation/devicemanagement/restrictions)

## Product-copy rule

- In-app copy must describe app enforcement as screenshot detection plus live-capture redaction.
- In-app copy must not claim the app itself blocks still screenshots on unmanaged devices.
- If MDM is deployed, treat it as a stronger external control that sits above the app’s own protection behavior.
