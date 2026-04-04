import SwiftUI

/// Phone number input screen for authentication.
/// Matches Figma: login-screen with VyncChat branding.
struct LoginView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = AuthViewModel()
    /// Common country codes for the selector.
    private let countryCodes = [
        ("+1", "US"), ("+44", "UK"), ("+91", "IN"), ("+61", "AU"),
        ("+81", "JP"), ("+49", "DE"), ("+33", "FR"), ("+86", "CN"),
        ("+55", "BR"), ("+234", "NG"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SanchrSpacing.xxl) {
                    Spacer().frame(height: SanchrSpacing.xxxxl)

                    // MARK: - Logo & Title
                    logoSection

                    // MARK: - Phone Input
                    phoneInputSection

                    // MARK: - Helper Text
                    Text("We'll send you a verification code")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))

                    // MARK: - E2EE Info Card
                    e2eeInfoCard

                    // MARK: - Continue Button
                    continueButton

                    Spacer().frame(height: SanchrSpacing.md)

                    // MARK: - Privacy & Terms
                    privacyLinks
                }
                .padding(.horizontal, SanchrSpacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .sanchrScreenBackground()
            .navigationDestination(isPresented: $viewModel.showOTPView) {
                OTPView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Logo Section

    private var logoSection: some View {
        VStack(spacing: SanchrSpacing.sm) {
            // Shield icon with gradient
            ZStack {
                Circle()
                    .fill(SanchrColors.primary.opacity(0.1))
                    .frame(width: 88, height: 88)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(SanchrGradients.primaryDark)
            }

            Text("Welcome to VyncChat")
                .font(SanchrTypography.screenTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                .multilineTextAlignment(.center)

            Text("Encrypted. Synced. Secure.")
                .font(SanchrTypography.body)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
        }
    }

    // MARK: - Phone Input Section

    private var phoneInputSection: some View {
        VStack(spacing: SanchrSpacing.xs) {
            HStack(spacing: SanchrSpacing.xs) {
                // Country code selector
                Menu {
                    ForEach(countryCodes, id: \.0) { code, label in
                        Button {
                            viewModel.countryCode = code
                        } label: {
                            HStack {
                                Text("\(code) \(label)")
                                if viewModel.countryCode == code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: SanchrSpacing.xxs) {
                        Text(viewModel.countryCode)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                    }
                    .padding(.horizontal, SanchrSpacing.sm)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(Color.sanchrSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                    .overlay(
                        RoundedRectangle(cornerRadius: SanchrRadius.input)
                            .stroke(Color.sanchrBorder(colorScheme), lineWidth: 1)
                    )
                }

                // Phone number text field
                TextField("Phone number", text: $viewModel.phoneNumber)
                    .font(SanchrTypography.body)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding(.horizontal, SanchrSpacing.sm)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(Color.sanchrSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                    .overlay(
                        RoundedRectangle(cornerRadius: SanchrRadius.input)
                            .stroke(Color.sanchrBorder(colorScheme), lineWidth: 1)
                    )
            }

            // Error message
            if let error = viewModel.errorMessage {
                HStack(spacing: SanchrSpacing.xxs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(error)
                        .font(SanchrTypography.caption)
                }
                .foregroundColor(.sanchrError)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - E2EE Info Card

    private var e2eeInfoCard: some View {
        HStack(spacing: SanchrSpacing.sm) {
            ZStack {
                Circle()
                    .fill(SanchrColors.primary.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.sanchrPrimary)
            }

            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                Text("End-to-End Encrypted")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                Text("Your messages are secured with the Signal Protocol")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }

            Spacer()
        }
        .padding(SanchrSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: SanchrRadius.card)
                .fill(SanchrColors.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: SanchrRadius.card)
                        .stroke(SanchrColors.primary.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        Button {
            Task { @MainActor in await viewModel.requestOTP(authService: container.authService) }
        } label: {
            HStack(spacing: SanchrSpacing.xs) {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Continue")
                        .font(SanchrTypography.button)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SanchrSpacing.md)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x6366F1), Color(hex: 0x4C1D95)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
        }
        .disabled(!viewModel.isPhoneValid || viewModel.isLoading)
        .opacity(viewModel.isPhoneValid ? 1.0 : 0.5)
        .sanchrPrimaryGlow()
    }

    // MARK: - Privacy Links

    private var privacyLinks: some View {
        HStack(spacing: SanchrSpacing.xxs) {
            Text("By continuing, you agree to our")
                .font(SanchrTypography.micro)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))

            Button("Privacy Policy") {
                // TODO: Open privacy policy URL
            }
            .font(SanchrTypography.micro)
            .foregroundColor(.sanchrPrimary)

            Text("and")
                .font(SanchrTypography.micro)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))

            Button("Terms of Service") {
                // TODO: Open terms URL
            }
            .font(SanchrTypography.micro)
            .foregroundColor(.sanchrPrimary)
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, SanchrSpacing.md)
    }

}
