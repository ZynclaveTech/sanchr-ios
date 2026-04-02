import SwiftUI

/// Registration screen for new accounts.
/// Matches Figma: register-screen.
struct RegisterView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = AuthViewModel()

    var body: some View {
        VStack(spacing: SanchrSpacing.xxl) {
            Spacer()

            // MARK: - Header
            VStack(spacing: SanchrSpacing.sm) {
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.sanchrPrimary)

                Text("Create Account")
                    .font(SanchrTypography.screenTitle)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                Text("Set up your Sanchr profile")
                    .font(SanchrTypography.body)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }

            // MARK: - Form
            VStack(spacing: SanchrSpacing.md) {
                // Display Name
                TextField("Display name", text: $viewModel.displayName)
                    .font(SanchrTypography.body)
                    .textContentType(.name)
                    .padding(.horizontal, SanchrSpacing.sm)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(Color.sanchrSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))

                // Phone Number
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

            // MARK: - Register Button
            Button {
                Task { await viewModel.register(authService: container.authService) }
            } label: {
                Group {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Create Account")
                            .font(SanchrTypography.button)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SanchrSpacing.sm)
                .background(SanchrGradients.primary)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
            }
            .disabled(viewModel.displayName.isEmpty || viewModel.phoneNumber.isEmpty || viewModel.isLoading)
            .padding(.horizontal, SanchrSpacing.xl)
            .sanchrPrimaryGlow()

            // MARK: - Encryption Notice
            HStack(spacing: SanchrSpacing.xxs) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("End-to-end encrypted from day one")
                    .font(SanchrTypography.captionSmall)
            }
            .foregroundColor(SanchrColors.encryptionBadgeText)
            .padding(.horizontal, SanchrSpacing.sm)
            .padding(.vertical, SanchrSpacing.xxs)
            .background(SanchrColors.encryptionBadge)
            .clipShape(Capsule())

            Spacer()
        }
        .sanchrScreenBackground()
        .navigationBarBackButtonHidden(false)
    }
}
