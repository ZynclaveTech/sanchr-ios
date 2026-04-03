import SwiftUI

struct OnboardingNameStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Step indicator
            Text("STEP 1 OF 3")
                .font(SanchrTypography.micro)
                .foregroundColor(.sanchrPrimary)
                .kerning(2.5)
                .padding(.bottom, SanchrSpacing.sm)

            // Title
            Text("What's your name?")
                .font(SanchrTypography.screenTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                .padding(.bottom, SanchrSpacing.xs)

            // Subtitle
            Text("This is how others will see you on Sanchr")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                .padding(.bottom, SanchrSpacing.xxxl)

            // Name input
            TextField("Enter your name", text: $viewModel.displayName)
                .font(SanchrTypography.body)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                .padding(SanchrSpacing.md)
                .background(Color.sanchrSurface(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: SanchrRadius.button)
                        .stroke(Color.sanchrBorder(colorScheme), lineWidth: 1)
                )
                .focused($isNameFocused)
                .textInputAutocapitalization(.words)
                .submitLabel(.continue)
                .onChange(of: viewModel.displayName) { _, newValue in
                    if newValue.count > 40 {
                        viewModel.displayName = String(newValue.prefix(40))
                    }
                }
                .onSubmit {
                    if viewModel.isNameValid {
                        viewModel.goToNextStep()
                    }
                }
                .padding(.horizontal, SanchrSpacing.xxl)

            Spacer()

            // Progress + Continue
            VStack(spacing: SanchrSpacing.xl) {
                OnboardingProgressIndicator(currentStep: 1)

                Button {
                    viewModel.goToNextStep()
                } label: {
                    Text("Continue")
                        .font(SanchrTypography.button)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SanchrSpacing.md)
                        .background(SanchrGradients.primary)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                        .opacity(viewModel.isNameValid ? 1.0 : 0.4)
                }
                .disabled(!viewModel.isNameValid)
                .padding(.horizontal, SanchrSpacing.xxl)
            }
            .padding(.bottom, SanchrSpacing.xxxxl)
        }
        .sanchrScreenBackground()
        .onAppear { isNameFocused = true }
    }
}
