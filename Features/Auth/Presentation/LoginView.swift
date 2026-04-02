import SwiftUI

/// Phone number input screen for authentication.
/// Matches Figma: login-screen.
struct LoginView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = AuthViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: SanchrSpacing.xxl) {
                Spacer()

                // MARK: - Logo & Title
                VStack(spacing: SanchrSpacing.sm) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(SanchrGradients.primary)

                    Text("Sanchr")
                        .font(SanchrTypography.heroTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Text("Private. Secure. Yours.")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }

                // MARK: - Phone Input
                VStack(spacing: SanchrSpacing.md) {
                    HStack(spacing: SanchrSpacing.xs) {
                        Text(viewModel.countryCode)
                            .font(SanchrTypography.body)
                            .padding(.horizontal, SanchrSpacing.sm)
                            .padding(.vertical, SanchrSpacing.sm)
                            .background(Color.sanchrSurface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))

                        TextField("Phone number", text: $viewModel.phoneNumber)
                            .font(SanchrTypography.body)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .padding(.horizontal, SanchrSpacing.sm)
                            .padding(.vertical, SanchrSpacing.sm)
                            .background(Color.sanchrSurface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrError)
                    }
                }
                .padding(.horizontal, SanchrSpacing.xl)

                // MARK: - Continue Button
                Button {
                    Task { await viewModel.requestOTP(authService: container.authService) }
                } label: {
                    Group {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Continue")
                                .font(SanchrTypography.button)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(SanchrGradients.primary)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                }
                .disabled(viewModel.phoneNumber.isEmpty || viewModel.isLoading)
                .padding(.horizontal, SanchrSpacing.xl)
                .sanchrPrimaryGlow()

                Spacer()

                // MARK: - Register Link
                NavigationLink {
                    RegisterView()
                } label: {
                    Text("Don't have an account? ")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    + Text("Register")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrPrimary)
                }
                .padding(.bottom, SanchrSpacing.xl)
            }
            .sanchrScreenBackground()
            .navigationDestination(isPresented: $viewModel.showOTPView) {
                OTPView(viewModel: viewModel)
            }
        }
    }
}
