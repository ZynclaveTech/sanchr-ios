import SwiftUI
import SanchrShared

/// Step 4: contact discovery. This used to fire the notification permission
/// prompt as a side effect of Continue or Skip, with no explanation; that
/// now has its own step.
struct OnboardingContactSyncStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinish: () -> Void

    var body: some View {
        ContactSyncView(
            onBack: {
                viewModel.goToPreviousStep()
            },
            onFinish: onFinish
        )
    }
}
