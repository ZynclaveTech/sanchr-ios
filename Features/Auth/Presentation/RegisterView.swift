import SwiftUI

/// Registration screen for new accounts.
/// Matches Figma: register-screen with profile photo, display name, and phone.
struct RegisterView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = AuthViewModel()
    @State private var showImagePicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: SanchrSpacing.xxl) {
                Spacer().frame(height: SanchrSpacing.xl)

                // MARK: - Header
                VStack(spacing: SanchrSpacing.sm) {
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(SanchrGradients.primaryDark)

                    Text("Create Account")
                        .font(SanchrTypography.screenTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Text("Set up your VyncChat profile")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }

                // MARK: - Profile Photo Placeholder
                profilePhotoSection

                // MARK: - Form Fields
                VStack(spacing: SanchrSpacing.md) {
                    // Display Name
                    VStack(alignment: .leading, spacing: SanchrSpacing.xxs) {
                        Text("Display Name")
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                        TextField("Enter your name", text: $viewModel.displayName)
                            .font(SanchrTypography.body)
                            .textContentType(.name)
                            .autocorrectionDisabled()
                            .padding(.horizontal, SanchrSpacing.sm)
                            .padding(.vertical, SanchrSpacing.sm)
                            .background(Color.sanchrSurface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                            .overlay(
                                RoundedRectangle(cornerRadius: SanchrRadius.input)
                                    .stroke(Color.sanchrBorder(colorScheme), lineWidth: 1)
                            )
                    }

                    // Phone Number
                    VStack(alignment: .leading, spacing: SanchrSpacing.xxs) {
                        Text("Phone Number")
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                        HStack(spacing: SanchrSpacing.xs) {
                            Text(viewModel.countryCode)
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                                .padding(.horizontal, SanchrSpacing.sm)
                                .padding(.vertical, SanchrSpacing.sm)
                                .background(Color.sanchrSurface(colorScheme))
                                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                                .overlay(
                                    RoundedRectangle(cornerRadius: SanchrRadius.input)
                                        .stroke(Color.sanchrBorder(colorScheme), lineWidth: 1)
                                )

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
                    }
                }
                .padding(.horizontal, SanchrSpacing.xl)

                // MARK: - Create Account Button
                Button {
                    Task { await viewModel.register(authService: container.authService) }
                } label: {
                    HStack(spacing: SanchrSpacing.xs) {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Create your account")
                                .font(SanchrTypography.button)
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
                .disabled(!viewModel.isRegistrationValid || viewModel.isLoading)
                .opacity(viewModel.isRegistrationValid ? 1.0 : 0.5)
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
                .padding(.vertical, SanchrSpacing.xs)
                .background(SanchrColors.encryptionBadge)
                .clipShape(Capsule())

                Spacer().frame(height: SanchrSpacing.xl)
            }
        }
        .sanchrScreenBackground()
        .navigationBarBackButtonHidden(false)
        .navigationDestination(isPresented: $viewModel.showOTPView) {
            OTPView(viewModel: viewModel)
        }
    }

    // MARK: - Profile Photo Section

    private var profilePhotoSection: some View {
        Button {
            showImagePicker = true
        } label: {
            ZStack {
                if let imageData = viewModel.profileImageData,
                    let uiImage = UIImage(data: imageData)
                {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(SanchrColors.primary.opacity(0.1))
                        .frame(width: 100, height: 100)
                        .overlay {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 28))
                                .foregroundColor(SanchrColors.primary.opacity(0.6))
                        }
                }

                // Camera badge
                Circle()
                    .fill(Color.sanchrPrimary)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .offset(x: 36, y: 36)
            }
        }
    }
}
