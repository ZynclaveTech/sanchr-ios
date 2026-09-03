import SwiftUI
import SanchrShared

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

                Text(viewModel.displayPhoneNumber)
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

            // MARK: - Expiry + Resend
            VStack(spacing: SanchrSpacing.xs) {
                // The code's real lifetime, from the server. The resend
                // cooldown used to stand in for it, so nothing ever said a
                // code had stopped working.
                if viewModel.isOTPExpired {
                    Text("This code has expired")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                } else if viewModel.otpSecondsRemaining > 0 {
                    Text("Code expires in \(viewModel.formattedOTPExpiry)")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                        .monospacedDigit()
                        .accessibilityLabel("Code expires in \(viewModel.otpSecondsRemaining) seconds")
                }

                if viewModel.resendCountdown > 0 {
                    Text("Resend in \(viewModel.formattedCountdown)")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                        .monospacedDigit()
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
                        .accessibilityLabel("Resend code")
                        .accessibilityHint("Sends a new verification code by text message")
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
                .accessibilityLabel("Back to phone number")
            }
        }
        .onAppear { isFocused = true }
        .alert("Registration Lock", isPresented: $viewModel.showRegistrationLockPIN) {
            SecureField("Enter your PIN", text: $viewModel.registrationLockPIN)
                .keyboardType(.numberPad)
            Button("Submit") {
                Task {
                    await viewModel.submitRegistrationLockPIN(authService: container.authService)
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelRegistrationLockPIN()
            }
        } message: {
            Text("This account has a registration lock. Enter your PIN to continue.")
        }
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
        // VoiceOver read six unlabelled characters; the real control is the
        // hidden field, so it carries the label and the progress.
        .accessibilityHidden(true)
        .overlay {
            // Hidden text field for keyboard input
            TextField("", text: $viewModel.otpCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.01)  // Invisible but captures input
                .accessibilityLabel("Verification code")
                .accessibilityValue("\(viewModel.otpCode.count) of 6 digits entered")
                .accessibilityHint("Enter the 6-digit code from the text message")
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
