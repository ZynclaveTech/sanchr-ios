import SwiftUI
import SanchrShared

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

                SettingsIconTile(systemName: "lock.shield", role: .accent, size: 100, iconSize: 48)

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
                            .symbolRenderingMode(.monochrome)
                            .font(.title2)
                        Text("Unlock")
                            .font(SanchrTypography.button)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SanchrSpacing.md)
                    .background(Color.sanchrPrimary)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                }
                .padding(.horizontal, SanchrSpacing.xxl)
                .padding(.bottom, SanchrSpacing.xxxxl)
            }
        }
    }
}
