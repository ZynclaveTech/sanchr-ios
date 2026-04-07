import SwiftUI
import SanchrShared

struct SplashView: View {
    var body: some View {
        ZStack {
            SanchrExportColors.background
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 96, height: 96)
                        .overlay {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 42, weight: .semibold))
                                .foregroundColor(.white)
                        }

                    Circle()
                        .fill(SanchrColors.accent)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .offset(x: 6, y: 6)
                }

                VStack(spacing: 8) {
                    Text("Sanchr")
                        .font(SanchrTypography.heroTitle)
                        .foregroundColor(SanchrExportColors.textPrimary)

                    Text("Encrypted. Synced. Secure.")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.sanchrPrimary)
                    Text("Initializing secure connection...")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
                .padding(.bottom, 60)
            }
            .padding(.horizontal, 28)
        }
    }
}
