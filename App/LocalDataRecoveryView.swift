import SwiftUI

struct LocalDataRecoveryView: View {
    @Environment(\.colorScheme) private var colorScheme

    let error: AppError
    let recoverAction: @Sendable () async -> Void

    @State private var isRecovering = false

    var body: some View {
        VStack(spacing: SanchrSpacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.sanchrPrimary)

            Text("Local Data Reset Required")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            Text(error.errorDescription ?? "Sanchr could not open its encrypted local data.")
                .font(SanchrTypography.body)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                .multilineTextAlignment(.center)

            Text("Reset local app data to create a fresh encrypted database. Your server-side account stays intact.")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                .multilineTextAlignment(.center)

            Button {
                isRecovering = true
                Task {
                    await recoverAction()
                    isRecovering = false
                }
            } label: {
                if isRecovering {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Reset Local Data")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.sanchrPrimary)
            .disabled(isRecovering)
        }
        .padding(SanchrSpacing.xl)
        .frame(maxWidth: 420)
    }
}
