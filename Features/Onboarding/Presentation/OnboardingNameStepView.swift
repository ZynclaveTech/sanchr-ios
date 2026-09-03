import SwiftUI
import SanchrShared

struct OnboardingNameStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 44)

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xEEF2FF), Color(hex: 0xECFEFF)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 108, height: 108)
                .overlay {
                    Image("SanchrLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                }
                .padding(.bottom, 28)

            Text("STEP 1 OF \(OnboardingViewModel.totalSteps)")
                .font(SanchrTypography.micro)
                .foregroundColor(.sanchrPrimary)
                .kerning(2.5)
                .padding(.bottom, 12)

            Text("What's your name?")
                .font(SanchrTypography.displayTitle)
                .foregroundColor(SanchrExportColors.textPrimary)
                .padding(.bottom, 8)

            Text("This is how people will see you on Sanchr.")
                .font(SanchrTypography.body)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 30)

            TextField("Enter your name", text: $viewModel.displayName)
                .font(SanchrTypography.body)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(SanchrExportColors.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

            Spacer()

            VStack(spacing: 18) {
                OnboardingProgressIndicator(currentStep: 1)

                Button {
                    viewModel.goToNextStep()
                } label: {
                    SanchrGradientButtonLabel(title: "Continue", systemName: nil)
                }
                .buttonStyle(SanchrPrimaryCTA())
                .disabled(!viewModel.isNameValid)
                .opacity(viewModel.isNameValid ? 1 : 0.5)
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            }
            .padding(.bottom, 36)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .onAppear { isNameFocused = true }
    }
}
