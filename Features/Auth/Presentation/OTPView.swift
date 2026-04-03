import SwiftUI

/// OTP verification screen with 6-digit input boxes.
/// Matches Figma: otp-verification-screen.
struct OTPView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var viewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: SanchrSpacing.xxl) {
            Spacer()

            // MARK: - Header
            VStack(spacing: SanchrSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(SanchrColors.primary.opacity(0.1))
                        .frame(width: 72, height: 72)

                    Image(systemName: "ellipsis.rectangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(SanchrGradients.primaryDark)
                }

                Text("Verify your number")
                    .font(SanchrTypography.screenTitle)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                Text("Enter the 6-digit code sent to")
                    .font(SanchrTypography.body)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                Text(viewModel.fullPhoneNumber)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
            }
            .multilineTextAlignment(.center)

            // MARK: - OTP Input Boxes
            otpInputBoxes

            // Loading indicator
            if viewModel.isLoading {
                ProgressView()
                    .tint(.sanchrPrimary)
                    .scaleEffect(1.2)
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

            // MARK: - Resend Section
            VStack(spacing: SanchrSpacing.xs) {
                if viewModel.resendCountdown > 0 {
                    Text("Resend in \(viewModel.formattedCountdown)")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                } else {
                    VStack(spacing: SanchrSpacing.xxs) {
                        Text("Didn't receive the code?")
                            .font(SanchrTypography.caption)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                        Button {
                            Task { await viewModel.resendOTP(authService: container.authService) }
                        } label: {
                            Text("Resend")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, SanchrSpacing.xl)
        .sanchrScreenBackground()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.goBackToPhone()
                    dismiss()
                } label: {
                    HStack(spacing: SanchrSpacing.xxs) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(SanchrTypography.body)
                    }
                    .foregroundColor(.sanchrPrimary)
                }
            }
        }
        .onAppear { isFocused = true }
    }

    // MARK: - OTP Input Boxes

    private var otpInputBoxes: some View {
        HStack(spacing: SanchrSpacing.xs) {
            ForEach(0..<6, id: \.self) { index in
                let digit = viewModel.otpDigit(at: index)
                let isCurrentBox = index == viewModel.otpCode.count
                let hasDigit = !digit.isEmpty

                Text(digit.isEmpty ? " " : digit)
                    .font(SanchrTypography.sectionHeader)
                    .frame(width: 48, height: 56)
                    .background(
                        hasDigit
                            ? SanchrColors.primary.opacity(0.05)
                            : Color.sanchrSurface(colorScheme)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                    .overlay(
                        RoundedRectangle(cornerRadius: SanchrRadius.input)
                            .stroke(
                                isCurrentBox
                                    ? Color.sanchrPrimary
                                    : hasDigit
                                        ? SanchrColors.primary.opacity(0.3)
                                        : Color.sanchrBorder(colorScheme),
                                lineWidth: isCurrentBox ? 2 : 1
                            )
                    )
                    .animation(.easeInOut(duration: 0.15), value: digit)
            }
        }
        .overlay {
            // Hidden text field for keyboard input
            TextField("", text: $viewModel.otpCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.01)  // Invisible but captures input
                .onChange(of: viewModel.otpCode) { _, newValue in
                    if newValue.count == 6 {
                        Task {
                            await viewModel.verifyOTP(authService: container.authService)
                        }
                    }
                }
        }
        .onTapGesture { isFocused = true }
    }
}
