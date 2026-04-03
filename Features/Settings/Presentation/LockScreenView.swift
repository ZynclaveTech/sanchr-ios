import SwiftUI

/// Full-screen overlay shown when the app is locked.
/// Displays the app icon and a button to trigger biometric/passcode authentication.
struct LockScreenView: View {
    let onAuthenticate: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.sanchrBackground(colorScheme)
                .ignoresSafeArea()

            VStack(spacing: SanchrSpacing.xl) {
                Spacer()

                // App icon
                ZStack {
                    Circle()
                        .fill(SanchrColors.primary.opacity(0.1))
                        .frame(width: 100, height: 100)

                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(SanchrGradients.primaryDark)
                }

                Text("Sanchr is Locked")
                    .font(SanchrTypography.screenTitle)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                Text("Authenticate to continue")
                    .font(SanchrTypography.body)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                Spacer()

                Button {
                    onAuthenticate()
                } label: {
                    HStack(spacing: SanchrSpacing.xs) {
                        Image(systemName: "faceid")
                            .font(.title2)
                        Text("Unlock")
                            .font(SanchrTypography.button)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SanchrSpacing.md)
                    .background(SanchrGradients.primary)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                }
                .padding(.horizontal, SanchrSpacing.xxl)
                .padding(.bottom, SanchrSpacing.xxxxl)
            }
        }
    }
}
