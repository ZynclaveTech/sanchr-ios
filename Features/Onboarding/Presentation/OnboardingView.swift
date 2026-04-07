import SwiftUI
import SanchrShared

// MARK: - Progress Indicator

struct OnboardingProgressIndicator: View {
    let currentStep: Int
    private let totalSteps = 3

    var body: some View {
        HStack(spacing: 8) {
            ForEach(1...totalSteps, id: \.self) { step in
                Capsule()
                    .fill(step <= currentStep ? Color.sanchrPrimary : Color(hex: 0xE5E7EB))
                    .frame(width: 34, height: 6)
            }
        }
    }
}

// MARK: - Onboarding Container

struct OnboardingView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = OnboardingViewModel()
    let onFinish: () -> Void

    private var profileDataSource: ProfileDataSource {
        ProfileDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        ZStack {
            switch viewModel.currentStep {
            case 1:
                OnboardingNameStepView(viewModel: viewModel)
                    .transition(stepTransition)
            case 2:
                OnboardingAvatarStepView(
                    viewModel: viewModel,
                    profileDataSource: profileDataSource,
                    mediaManager: container.mediaManager,
                    sessionService: container.sessionService
                )
                .transition(stepTransition)
            case 3:
                OnboardingContactSyncStepView(
                    viewModel: viewModel,
                    pushManager: container.pushManager,
                    onFinish: onFinish
                )
                .transition(stepTransition)
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.currentStep)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: viewModel.isForward ? .trailing : .leading),
            removal: .move(edge: viewModel.isForward ? .leading : .trailing)
        )
    }
}
