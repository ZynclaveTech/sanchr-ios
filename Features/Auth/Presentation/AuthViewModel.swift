import Combine
import Foundation
import SanchrShared

/// State machine for the authentication flow.
/// Drives LoginView, OTPView, and RegisterView through a linear progression.
@MainActor
@Observable
final class AuthViewModel {

    // MARK: - Auth Flow State Machine

    enum AuthState: Equatable {
        case idle
        case enterPhone
        case enterOTP
        case enterProfile
        case authenticated
    }

    private(set) var authState: AuthState = .enterPhone

    // MARK: - Input State

    var phoneNumber: String = ""
    var countryCode: String = "+1"
    var displayName: String = ""
    var profileImageData: Data?
    var otpCode: String = "" {
        didSet {
            // Strip non-digits and cap at 6
            let digits = otpCode.filter(\.isNumber)
            if digits != otpCode || digits.count > 6 {
                otpCode = String(digits.prefix(6))
            }
        }
    }

    // MARK: - UI State

    var isLoading: Bool = false
    var errorMessage: String?
    var showOTPView: Bool = false
    var showRegisterView: Bool = false
    var resendCountdown: Int = 0

    // MARK: - Validation

    /// Whether the phone input is valid for submission.
    var isPhoneValid: Bool {
        let cleaned = phoneNumber.filter(\.isNumber)
        return cleaned.count >= 7 && cleaned.count <= 15
    }

    /// Whether the OTP code is complete.
    var isOTPComplete: Bool {
        otpCode.count == 6
    }

    /// Whether the registration form is valid.
    var isRegistrationValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isPhoneValid
    }

    // MARK: - Internal State

    private var otpRequestId: String?
    private var resendTimer: Timer?

    // MARK: - Computed

    var fullPhoneNumber: String {
        "\(countryCode)\(phoneNumber)"
    }

    /// Formatted countdown for display: "0:30"
    var formattedCountdown: String {
        let minutes = resendCountdown / 60
        let seconds = resendCountdown % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Returns the digit at the given OTP position, or empty string.
    func otpDigit(at index: Int) -> String {
        guard index < otpCode.count else { return "" }
        let charIndex = otpCode.index(otpCode.startIndex, offsetBy: index)
        return String(otpCode[charIndex])
    }

    // MARK: - State Transitions

    func goToOTP() {
        authState = .enterOTP
    }

    func goToProfile() {
        authState = .enterProfile
    }

    func goBackToPhone() {
        authState = .enterPhone
        otpCode = ""
        errorMessage = nil
        resendTimer?.invalidate()
        resendCountdown = 0
    }

    // MARK: - Actions

    /// Request OTP: validates phone, calls auth service, transitions to OTP screen.
    func requestOTP(authService: AuthServiceProtocol) async {
        guard isPhoneValid else {
            errorMessage = "Please enter a valid phone number."
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await authService.login(phoneNumber: fullPhoneNumber)
            otpRequestId = result.requestId
            authState = .enterOTP
            showOTPView = true
            startResendCountdown(seconds: result.expiresInSeconds)
            SanchrLogger.auth.info("OTP requested successfully")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.auth.error("OTP request failed: \(error.localizedDescription)")
        }
    }

    /// Verify OTP: validates 6-digit code, calls auth service, handles success/failure.
    func verifyOTP(authService: AuthServiceProtocol) async {
        guard let requestId = otpRequestId else {
            errorMessage = "Please request a new verification code."
            return
        }

        guard isOTPComplete else {
            errorMessage = "Please enter all 6 digits."
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
            // Session is now authenticated; RootView observes sessionService.isAuthenticated
            authState = .authenticated
            resendTimer?.invalidate()
            SanchrLogger.auth.info("OTP verified successfully")
        } catch let error as AppError where error == .otpInvalid || error == .otpExpired {
            errorMessage = error.localizedDescription
            otpCode = ""
        } catch {
            errorMessage = error.localizedDescription
            otpCode = ""
        }
    }

    /// Resend OTP: resets the code and re-requests.
    func resendOTP(authService: AuthServiceProtocol) async {
        guard resendCountdown == 0 else { return }
        otpCode = ""
        errorMessage = nil
        await requestOTP(authService: authService)
    }

    /// Register: validates inputs, creates account, handles OTP flow.
    func register(authService: AuthServiceProtocol) async {
        guard isRegistrationValid else {
            errorMessage = "Please fill in all required fields."
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await authService.register(
                phoneNumber: fullPhoneNumber,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            otpRequestId = result.requestId
            authState = .enterOTP
            showOTPView = true
            startResendCountdown(seconds: result.expiresInSeconds)
            SanchrLogger.auth.info("Registration OTP requested successfully")
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.auth.error("Registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Timer

    private func startResendCountdown(seconds: Int) {
        resendCountdown = min(max(seconds, 30), 60)
        resendTimer?.invalidate()

        resendTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] timer in
            nonisolated(unsafe) let tmr = timer
            MainActor.assumeIsolated {
                guard let self else {
                    tmr.invalidate()
                    return
                }
                if self.resendCountdown > 0 {
                    self.resendCountdown -= 1
                } else {
                    tmr.invalidate()
                }
            }
        }
    }

    deinit {
        // Timer cleanup handled by SwiftUI view lifecycle
    }
}
