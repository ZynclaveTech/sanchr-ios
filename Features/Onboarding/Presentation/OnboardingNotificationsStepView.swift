import SanchrShared
import SwiftUI

/// Step 3: ask for notifications with a reason and a button, rather than
/// firing the one-shot system prompt as a side effect of finishing the
/// contact step. A user who declined here can still turn them on from
/// Settings → Notifications, and the app asks once more after onboarding
/// if the prompt was never shown at all.
struct OnboardingNotificationsStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    let pushManager: PushManager
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SanchrIconButton(systemName: "chevron.left") {
                    viewModel.goToPreviousStep()
                }
                .accessibilityLabel("Back")
                Spacer()
                OnboardingProgressIndicator(currentStep: 3)
                Spacer()
                Color.clear.frame(width: SanchrExportMetrics.iconButtonSize, height: SanchrExportMetrics.iconButtonSize)
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.top, SanchrExportMetrics.rootTop)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Text("STEP 3 OF \(OnboardingViewModel.totalSteps)")
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.semibold)
                        .foregroundColor(SanchrExportColors.textTertiary)
                        .padding(.top, 28)

                    SettingsIconTile(systemName: "bell.badge", role: .accent, size: 88, iconSize: 36)

                    Text("Know when someone writes")
                        .font(SanchrTypography.screenTitle)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Sanchr uses notifications for new messages and incoming calls. A notification only says something arrived; the content stays end-to-end encrypted on your device.")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 12) {
                Button {
                    guard !isRequesting else { return }
                    isRequesting = true
                    Task {
                        await viewModel.requestNotificationPermission(pushManager: pushManager)
                        isRequesting = false
                        viewModel.goToNextStep()
                    }
                } label: {
                    SanchrGradientButtonLabel(title: isRequesting ? "Asking…" : "Turn on notifications", systemName: nil)
                }
                .buttonStyle(SanchrPrimaryCTA())
                .disabled(isRequesting)
                .accessibilityHint("Shows the system permission prompt")

                Button("Not now") {
                    viewModel.goToNextStep()
                }
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textSecondary)
                .accessibilityHint("You can turn notifications on later in Settings")
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
    }
}
