import SwiftUI

struct OnboardingContactSyncStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    let pushManager: PushManager
    let onFinish: () -> Void

    var body: some View {
        ContactSyncView(
            onBack: {
                viewModel.goToPreviousStep()
            },
            onFinish: {
                Task {
                    await viewModel.requestNotificationPermission(pushManager: pushManager)
                    onFinish()
                }
            }
        )
    }
}
