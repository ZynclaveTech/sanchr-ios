import Combine
import Foundation
import GRPC
import SanchrShared

/// State machine for the authentication flow.
/// Drives LoginView and OTPView through a linear progression.
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

    /// National digits only: the field shows them formatted, the server gets
    /// them as E.164 with the country's calling code.
    var phoneNumber: String = "" {
        didSet {
            let national = country.nationalNumber(from: phoneNumber)
            if national != phoneNumber { phoneNumber = national }
        }
    }
    var country: PhoneCountry = PhoneCountry.detected {
        didSet { phoneNumber = country.nationalNumber(from: phoneNumber) }
    }
    var countryCode: String { country.callingCode }
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
    /// Seconds until Resend is allowed. A short cooldown, independent of the
    /// code's lifetime; this used to be the server TTL clamped to a minute,
    /// which told the user nothing about when the code stopped working.
    var resendCountdown: Int = 0
    /// Seconds until the code the server sent stops being accepted.
    var otpSecondsRemaining: Int = 0
    var isOTPExpired: Bool { otpRequestId != nil && otpSecondsRemaining == 0 }
    var showRegistrationLockPIN: Bool = false
    var registrationLockPIN: String = ""

    // MARK: - Validation

    /// Whether the phone input is valid for submission.
    var isPhoneValid: Bool {
        country.isValid(nationalNumber: phoneNumber)
    }

    /// The field's text: formatted for reading, digits underneath.
    var formattedPhoneNumber: String {
        country.format(nationalNumber: phoneNumber)
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
        country.e164(nationalNumber: phoneNumber)
    }

    /// The number as a person would read it back: "+91 98765 43210".
    var displayPhoneNumber: String {
        "\(countryCode) \(formattedPhoneNumber)"
    }

    /// Formatted countdown for display: "0:30"
    var formattedCountdown: String { Self.clock(resendCountdown) }
    var formattedOTPExpiry: String { Self.clock(otpSecondsRemaining) }

    private static func clock(_ total: Int) -> String {
        String(format: "%d:%02d", total / 60, total % 60)
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
        otpRequestId = nil
        errorMessage = nil
        resendTimer?.invalidate()
        resendCountdown = 0
        otpSecondsRemaining = 0
    }

    /// The registration-lock prompt was dismissed. Six digits stayed in the
    /// boxes with no error and no way to resubmit; clear them so the next
    /// keystroke starts a fresh attempt.
    func cancelRegistrationLockPIN() {
        showRegistrationLockPIN = false
        registrationLockPIN = ""
        otpCode = ""
    }

    // MARK: - Actions

    /// Request OTP: validates phone, calls auth service, transitions to OTP screen.
    func requestOTP(authService: AuthServiceProtocol) async {
        guard isPhoneValid else {
            errorMessage = "Enter a valid \(country.name) mobile number."
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
            errorMessage = Self.userMessage(for: error)
            SanchrLogger.auth.error("OTP request failed: \(error.localizedDescription)")
        }
    }

    /// Verify OTP: validates 6-digit code, calls auth service, handles success/failure.
    func verifyOTP(authService: AuthServiceProtocol, registrationLockPin: String? = nil) async {
        guard let requestId = otpRequestId else {
            errorMessage = "Please request a new verification code."
            return
        }

        guard isOTPComplete else {
            errorMessage = "Please enter all 6 digits."
            return
        }

        guard !isOTPExpired else {
            errorMessage = "That code has expired. Request a new one."
            otpCode = ""
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService.verifyOTP(
                phoneNumber: fullPhoneNumber,
                code: otpCode,
                requestId: requestId,
                registrationLockPin: registrationLockPin
            )
            // Session is now authenticated; RootView observes sessionService.isAuthenticated
            authState = .authenticated
            resendTimer?.invalidate()
            SanchrLogger.auth.info("OTP verified successfully")
        } catch let error as AppError where error == .registrationLockPinRequired {
            SanchrLogger.auth.info("Registration lock PIN required, showing prompt")
            showRegistrationLockPIN = true
        } catch {
            errorMessage = Self.userMessage(for: error)
            otpCode = ""
        }
    }

    /// Retry OTP verification with the registration lock PIN.
    func submitRegistrationLockPIN(authService: AuthServiceProtocol) async {
        let pin = registrationLockPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else {
            errorMessage = "Please enter your registration lock PIN."
            return
        }
        showRegistrationLockPIN = false
        await verifyOTP(authService: authService, registrationLockPin: pin)
        registrationLockPIN = ""
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
            errorMessage = Self.userMessage(for: error)
            SanchrLogger.auth.error("Registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Timer

    /// How long the user waits before asking for another code.
    static let resendCooldownSeconds = 30

    private func startResendCountdown(seconds: Int) {
        resendCountdown = Self.resendCooldownSeconds
        otpSecondsRemaining = max(seconds, 0)
        resendTimer?.invalidate()

        resendTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] timer in
            nonisolated(unsafe) let tmr = timer
            MainActor.assumeIsolated {
                guard let self else {
                    tmr.invalidate()
                    return
                }
                if self.resendCountdown > 0 { self.resendCountdown -= 1 }
                if self.otpSecondsRemaining > 0 { self.otpSecondsRemaining -= 1 }
                if self.resendCountdown == 0, self.otpSecondsRemaining == 0 {
                    tmr.invalidate()
                }
            }
        }
    }

    // MARK: - Error copy

    /// What the user reads when sign-in fails. `GRPCStatus` is not a
    /// `LocalizedError`, so showing `localizedDescription` produced
    /// "The operation couldn't be completed. (GRPC.GRPCStatus error 16.)".
    static func userMessage(for error: Error) -> String {
        if let appError = error as? AppError {
            switch appError {
            case .otpInvalid, .invalidCredentials:
                return "That code isn't right. Check the message and try again."
            case .otpExpired:
                return "That code has expired. Request a new one."
            case .networkUnavailable, .serverUnreachable:
                return "Can't reach Sanchr. Check your connection and try again."
            case .requestTimeout:
                return "That took too long. Check your connection and try again."
            case .accountLocked:
                return "This number is locked for now. Try again later."
            case .registrationLockPinRequired:
                return "This account has a registration lock. Enter your PIN to continue."
            case .registrationFailed(let reason):
                return reason.isEmpty ? "Couldn't register this number. Try again." : reason
            default:
                return appError.errorDescription ?? "Something went wrong. Try again in a moment."
            }
        }
        if let status = error as? GRPCStatus {
            switch status.code {
            case .unauthenticated, .permissionDenied:
                return "That code isn't right or has expired. Check the message and try again."
            case .resourceExhausted:
                return "Too many attempts. Wait a few minutes and try again."
            case .unavailable, .deadlineExceeded, .aborted:
                return "Can't reach Sanchr. Check your connection and try again."
            case .invalidArgument, .failedPrecondition:
                return "That doesn't look like a valid phone number for the selected country."
            case .notFound:
                return "No account was found for this number."
            default:
                return "Something went wrong. Try again in a moment."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach Sanchr. Check your connection and try again."
            case .timedOut:
                return "That took too long. Check your connection and try again."
            default:
                break
            }
        }
        return "Something went wrong. Try again in a moment."
    }

    deinit {
        // Timer cleanup handled by SwiftUI view lifecycle
    }
}
