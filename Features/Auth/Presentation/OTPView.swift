import SwiftUI

/// OTP verification screen.
/// Matches Figma: otp-verification-screen.
struct OTPView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var viewModel: AuthViewModel

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: SanchrSpacing.xxl) {
            Spacer()

            // MARK: - Header
            VStack(spacing: SanchrSpacing.sm) {
                Image(systemName: "ellipsis.rectangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.sanchrPrimary)

                Text("Verify your number")
                    .font(SanchrTypography.screenTitle)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                Text("Enter the 6-digit code sent to \(viewModel.fullPhoneNumber)")
                    .font(SanchrTypography.body)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    .multilineTextAlignment(.center)
            }

            // MARK: - OTP Input
            HStack(spacing: SanchrSpacing.xs) {
                ForEach(0..<6, id: \.self) { index in
                    let digit = viewModel.otpDigit(at: index)
                    Text(digit)
                        .font(SanchrTypography.screenTitle)
                        .frame(width: 48, height: 56)
                        .background(Color.sanchrSurface(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                        .overlay(
                            RoundedRectangle(cornerRadius: SanchrRadius.input)
                                .stroke(
                                    index == viewModel.otpCode.count
                                        ? Color.sanchrPrimary
                                        : Color.sanchrBorder(colorScheme),
                                    lineWidth: 1.5
                                )
                        )
                }
            }
            .overlay {
                TextField("", text: $viewModel.otpCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($isFocused)
                    .opacity(0.01) // Hidden but focusable
                    .onChange(of: viewModel.otpCode) { _, newValue in
                        if newValue.count == 6 {
                            Task {
                                await viewModel.verifyOTP(authService: container.authService)
                            }
                        }
                    }
            }
            .onTapGesture { isFocused = true }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(SanchrTypography.caption)
                    .foregroundColor(.sanchrError)
            }

            // MARK: - Resend
            Button {
                Task { await viewModel.resendOTP(authService: container.authService) }
            } label: {
                if viewModel.resendCountdown > 0 {
                    Text("Resend code in \(viewModel.resendCountdown)s")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                } else {
                    Text("Resend code")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrPrimary)
                }
            }
            .disabled(viewModel.resendCountdown > 0)

            Spacer()
        }
        .padding(.horizontal, SanchrSpacing.xl)
        .sanchrScreenBackground()
        .onAppear { isFocused = true }
    }
}
