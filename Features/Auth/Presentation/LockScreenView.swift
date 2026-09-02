import LocalAuthentication
import SanchrShared
import SwiftUI

/// The one lock screen: shown at cold launch by `AppLockGateView` and as the
/// foreground overlay by the root view. Both feed it the same three things —
/// whether a prompt is in flight, the last failure, and what to do on tap.
///
/// Design: the app's own mark with a small lock badge, on a quiet ground with
/// a breathing indigo glow, and one full-width unlock button that names the
/// method the device actually has. Nothing behind it is hinted at.
struct LockScreenView: View {
    var isAuthenticating: Bool = false
    var errorMessage: String? = nil
    let onUnlock: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing = false
    @State private var appeared = false

    private let biometry = LockBiometry.current

    var body: some View {
        ZStack {
            SanchrExportColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                mark
                    .padding(.bottom, SanchrSpacing.xxl)

                Text("Sanchr is locked")
                    .font(SanchrTypography.displayTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Your messages stay private until you unlock.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, SanchrSpacing.xs)
                    .padding(.horizontal, SanchrSpacing.xxl)

                Spacer()

                unlockButton
                    .padding(.horizontal, SanchrSpacing.xl)

                Group {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrError)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("End-to-end encrypted")
                                .font(SanchrTypography.captionSmall)
                        }
                        .foregroundColor(SanchrExportColors.textTertiary)
                    }
                }
                .frame(minHeight: 40)
                .padding(.horizontal, SanchrSpacing.xl)
                .padding(.bottom, SanchrSpacing.xl)
                .animation(.easeInOut(duration: 0.2), value: errorMessage)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glowing = true }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Mark

    private var mark: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.sanchrPrimary.opacity(colorScheme == .dark ? 0.32 : 0.18), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 120
                    )
                )
                .frame(width: 240, height: 240)
                .scaleEffect(glowing ? 1.08 : 0.94)
                .opacity(glowing ? 1 : 0.7)

            Image("SanchrLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .sanchrShadow(0.18, radius: 24, y: 12)

            // Lock badge on the mark's corner: "Sanchr, and it's locked" in one glyph.
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(
                        colors: [Color.sanchrPrimary, Color(hex: 0x4F46E5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .overlay(Circle().stroke(SanchrExportColors.background, lineWidth: 3))
                .offset(x: 44, y: 44)
        }
        .frame(width: 240, height: 240)
        .accessibilityHidden(true)
    }

    // MARK: - Button

    private var unlockButton: some View {
        Button(action: onUnlock) {
            HStack(spacing: SanchrSpacing.xs) {
                if isAuthenticating {
                    ProgressView()
                        .tint(.white)
                    Text("Unlocking\u{2026}")
                        .font(SanchrTypography.button)
                } else {
                    Image(systemName: biometry.symbolName)
                        .font(.system(size: 20, weight: .semibold))
                    Text(biometry.buttonTitle)
                        .font(SanchrTypography.button)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .foregroundColor(.white)
            .background(
                LinearGradient(
                    colors: [Color.sanchrPrimary, Color(hex: 0x4F46E5)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button, style: .continuous))
            .sanchrShadow(0.22, radius: 18, y: 8)
        }
        .disabled(isAuthenticating)
        .accessibilityLabel(biometry.buttonTitle)
        .accessibilityHint("Authenticates with the device to open Sanchr")
    }
}

extension LockScreenView {
    /// What to show for a failed prompt. A cancel is the user's own doing
    /// and gets no message; a lockout or a missing passcode gets a specific
    /// one; anything else gets the system's wording.
    nonisolated static func message(for error: Error) -> String? {
        guard let laError = error as? LAError else { return error.localizedDescription }
        switch laError.code {
        case .userCancel, .systemCancel, .appCancel:
            return nil
        case .biometryLockout:
            return "Too many attempts. Use your passcode to unlock."
        case .passcodeNotSet:
            return "Set a device passcode to unlock Sanchr."
        case .userFallback:
            return nil
        default:
            return laError.localizedDescription
        }
    }
}

/// Which unlock method the device offers, for the button's icon and title.
enum LockBiometry {
    case faceID, touchID, opticID, passcode

    static var current: LockBiometry {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .passcode
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    var symbolName: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .passcode: return "lock.open.fill"
        }
    }

    var buttonTitle: String {
        switch self {
        case .faceID: return "Unlock with Face ID"
        case .touchID: return "Unlock with Touch ID"
        case .opticID: return "Unlock with Optic ID"
        case .passcode: return "Unlock"
        }
    }
}

#Preview("Light") {
    LockScreenView(onUnlock: {})
}

#Preview("Dark, error") {
    LockScreenView(errorMessage: "Face ID didn't recognise you. Try again or use your passcode.", onUnlock: {})
        .preferredColorScheme(.dark)
}
