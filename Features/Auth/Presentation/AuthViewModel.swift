import Foundation

/// View model managing authentication state across Login, OTP, and Register screens.
@Observable
final class AuthViewModel {
    // MARK: - Input State

    var phoneNumber: String = ""
    var countryCode: String = "+1"
    var displayName: String = ""
    var otpCode: String = "" {
        didSet {
            // Limit OTP to 6 digits
            if otpCode.count > 6 {
                otpCode = String(otpCode.prefix(6))
            }
        }
    }

    // MARK: - UI State

    var isLoading: Bool = false
    var errorMessage: String?
    var showOTPView: Bool = false
    var resendCountdown: Int = 0

    // MARK: - Internal State

    private var otpRequestId: String?
    private var resendTimer: Timer?

    // MARK: - Computed

    var fullPhoneNumber: String {
        "\(countryCode)\(phoneNumber)"
    }

    /// Returns the digit at the given OTP position, or empty string.
    func otpDigit(at index: Int) -> String {
        guard index < otpCode.count else { return "" }
        let charIndex = otpCode.index(otpCode.startIndex, offsetBy: index)
        return String(otpCode[charIndex])
    }

    // MARK: - Actions

    func requestOTP(authService: AuthServiceProtocol) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await authService.login(phoneNumber: fullPhoneNumber)
            otpRequestId = result.requestId
            showOTPView = true
            startResendCountdown(seconds: result.expiresInSeconds)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func verifyOTP(authService: AuthServiceProtocol) async {
        guard let requestId = otpRequestId else {
            errorMessage = "Please request a new verification code."
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService.verifyOTP(
                phoneNumber: fullPhoneNumber,
                code: otpCode,
                requestId: requestId
            )
            // Session is now authenticated; RootView will switch to MainTabView
        } catch {
            errorMessage = error.localizedDescription
            otpCode = ""
        }
    }

    func resendOTP(authService: AuthServiceProtocol) async {
        guard resendCountdown == 0 else { return }
        otpCode = ""
        await requestOTP(authService: authService)
    }

    func register(authService: AuthServiceProtocol) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService.register(
                phoneNumber: fullPhoneNumber,
                displayName: displayName
            )
            // Session is now authenticated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Timer

    private func startResendCountdown(seconds: Int) {
        resendCountdown = min(seconds, 60)
        resendTimer?.invalidate()

        resendTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.resendCountdown > 0 {
                self.resendCountdown -= 1
            } else {
                timer.invalidate()
            }
        }
    }
}
