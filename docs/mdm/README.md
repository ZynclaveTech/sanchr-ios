# Screenshot Blocking on Managed Apple Devices

This folder contains the Apple configuration profile to disable screenshots and screen recording on managed devices:

- [disable-screenshots.mobileconfig](/Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/docs/mdm/disable-screenshots.mobileconfig)

The underlying Apple restriction is `allowScreenShot = false` in the `Restrictions` payload (`com.apple.applicationaccess`).

## Vendor Console Steps

### Jamf Pro

Use Jamf's native Restrictions payload when possible.

1. Open `Devices`.
2. Open `Configuration Profiles`.
3. Create a new profile for `iPhone and iPad`.
4. Add the `Restrictions` payload.
5. In the functionality restrictions, disable screenshots / screen capture.
6. Scope the profile to supervised or institutionally owned devices as required by your deployment.

Official references:

- [Jamf Pro: Restricting Access to Device Functionality for Mobile Devices](https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.20.0/Restricting_Device_Functionality_for_Mobile_Devices)

### Microsoft Intune

Use Intune's device restriction UI instead of uploading the `.mobileconfig`.

1. Open `Devices`.
2. Open `iOS/iPadOS`.
3. Open `Configuration`.
4. Create a policy using `Templates` -> `Device restrictions`, or use `Settings catalog`.
5. In `General`, set `Block screenshots and screen recording` to `Yes`.
6. Assign the policy to the target device group.

Official references:

- [Microsoft Intune: Apple device restriction settings](https://learn.microsoft.com/en-us/intune/intune-service/configuration/device-restrictions-ios)
- [Microsoft Intune: Turn on supervised mode for iOS/iPadOS](https://learn.microsoft.com/en-us/intune/intune-service/enrollment/device-supervised-mode)

### Kandji

Upload the provided `.mobileconfig` as a Custom Profile.

1. Open `Library`.
2. Click `Add Library Item`.
3. Choose `Custom Profile`.
4. Upload [disable-screenshots.mobileconfig](/Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/docs/mdm/disable-screenshots.mobileconfig).
5. Save the Library Item.
6. Open `Blueprints`.
7. Edit assignments for the target Blueprint.
8. Add the Custom Profile Library Item to the Blueprint and save.

Official references:

- [Kandji: Custom Profiles Overview](https://support.kandji.io/docs/custom-profiles-overview)
- [Kandji: Getting Started - Managing Your Library](https://support.kandji.io/kb/getting-started-managing-your-library)

## Notes

- On unmanaged consumer devices, the app can only detect screenshots after capture and redact during live capture.
- True OS-level screenshot blocking requires MDM policy on managed devices.
- The `.mobileconfig` in this folder is suitable for MDM systems that accept Apple custom profiles directly.
