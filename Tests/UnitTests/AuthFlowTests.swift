import Foundation
import GRPC
import SanchrShared
import XCTest
@testable import Sanchr

/// Phase 6 of the readiness plan: anyone can register (every country, with
/// validation for its numbering plan), sign-in errors read as sentences, the
/// code's expiry is visible, and the code entry works with VoiceOver.
@MainActor
final class AuthFlowTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Countries

    func testTheTableCoversTheWorldWithoutDuplicates() {
        let all = PhoneCountry.all
        XCTAssertGreaterThan(all.count, 230, "ten hardcoded countries locked everyone else out")
        XCTAssertEqual(Set(all.map(\.region)).count, all.count, "one entry per region")
        for country in all {
            XCTAssertEqual(country.region.count, 2, country.region)
            XCTAssertTrue(country.callingCode.hasPrefix("+") && country.callingDigits.count >= 1 && country.callingDigits.count <= 3, country.callingCode)
            XCTAssertTrue(country.nationalLength.lowerBound >= 4 && country.nationalLength.upperBound <= 13, "\(country.region) \(country.nationalLength)")
            XCTAssertFalse(country.name.isEmpty)
            XCTAssertEqual(country.flag.unicodeScalars.count, 2, "\(country.region) flag")
        }
        XCTAssertEqual(PhoneCountry.withRegion("IN")?.callingCode, "+91")
        XCTAssertEqual(PhoneCountry.withRegion("US")?.callingCode, "+1")
        XCTAssertEqual(PhoneCountry.withRegion("GB")?.callingCode, "+44")
        XCTAssertEqual(PhoneCountry.withRegion("NG")?.callingCode, "+234")
        XCTAssertEqual(PhoneCountry.withRegion("JP")?.callingCode, "+81")
        XCTAssertNotNil(PhoneCountry.withRegion("KE"), "a country the old list did not have")
    }

    func testNationalNumbersAreNormalisedPerPlan() throws {
        let india = try XCTUnwrap(PhoneCountry.withRegion("IN"))
        XCTAssertEqual(india.nationalNumber(from: "098765 43210"), "9876543210", "trunk zero and spaces dropped")
        XCTAssertTrue(india.isValid(nationalNumber: "9876543210"))
        XCTAssertFalse(india.isValid(nationalNumber: "987654321"), "nine digits is not an Indian mobile")
        XCTAssertEqual(india.e164(nationalNumber: "9876543210"), "+919876543210")
        XCTAssertEqual(india.format(nationalNumber: "9876543210"), "98765 43210")

        let us = try XCTUnwrap(PhoneCountry.withRegion("US"))
        XCTAssertEqual(us.nationalNumber(from: "(555) 123-4567"), "5551234567")
        XCTAssertEqual(us.nationalNumber(from: "05551234567"), "05551234567".prefix(10).description, "no trunk prefix in the NANP")
        XCTAssertFalse(us.isValid(nationalNumber: "0555123456"), "NANP numbers never start with 0")
        XCTAssertEqual(us.format(nationalNumber: "5551234567"), "(555) 123-4567")
        XCTAssertEqual(us.format(nationalNumber: "555"), "555")

        let uk = try XCTUnwrap(PhoneCountry.withRegion("GB"))
        XCTAssertEqual(uk.nationalNumber(from: "07911 123456"), "7911123456")
        XCTAssertTrue(uk.isValid(nationalNumber: "7911123456"))
        XCTAssertEqual(uk.e164(nationalNumber: "7911123456"), "+447911123456")

        let germany = try XCTUnwrap(PhoneCountry.withRegion("DE"))
        XCTAssertTrue(germany.isValid(nationalNumber: "1512345678"))
        XCTAssertTrue(germany.isValid(nationalNumber: "15123456789"), "German mobiles are 10 or 11 digits")
        XCTAssertEqual(germany.nationalNumber(from: "151234567891234"), "15123456789", "capped at the plan's longest")
    }

    func testTheViewModelKeepsDigitsAndBuildsE164() throws {
        let vm = AuthViewModel()
        vm.country = try XCTUnwrap(PhoneCountry.withRegion("IN"))
        vm.phoneNumber = "098765 43210"
        XCTAssertEqual(vm.phoneNumber, "9876543210")
        XCTAssertTrue(vm.isPhoneValid)
        XCTAssertEqual(vm.fullPhoneNumber, "+919876543210")
        XCTAssertEqual(vm.formattedPhoneNumber, "98765 43210")
        XCTAssertEqual(vm.displayPhoneNumber, "+91 98765 43210")
        vm.country = try XCTUnwrap(PhoneCountry.withRegion("US"))
        XCTAssertEqual(vm.fullPhoneNumber, "+19876543210", "switching country re-derives the number")
    }

    // MARK: - Error copy

    func testAuthErrorsReadAsSentences() {
        XCTAssertEqual(AuthViewModel.userMessage(for: AppError.otpInvalid), "That code isn't right. Check the message and try again.")
        XCTAssertEqual(AuthViewModel.userMessage(for: AppError.otpExpired), "That code has expired. Request a new one.")
        XCTAssertEqual(AuthViewModel.userMessage(for: GRPCStatus(code: .resourceExhausted, message: nil)), "Too many attempts. Wait a few minutes and try again.")
        XCTAssertEqual(AuthViewModel.userMessage(for: GRPCStatus(code: .unavailable, message: nil)), "Can't reach Sanchr. Check your connection and try again.")
        XCTAssertEqual(AuthViewModel.userMessage(for: GRPCStatus(code: .unauthenticated, message: nil)), "That code isn't right or has expired. Check the message and try again.")
        XCTAssertEqual(AuthViewModel.userMessage(for: URLError(.notConnectedToInternet)), "Can't reach Sanchr. Check your connection and try again.")
        let generic = AuthViewModel.userMessage(for: GRPCStatus(code: .internalError, message: nil))
        XCTAssertFalse(generic.contains("GRPCStatus"), "never a type name: \(generic)")
        XCTAssertFalse(generic.contains("error 1"), generic)
    }

    func testTheRepositoryMapsARejectedCodeToAppError() throws {
        let repository = try source("Shared/Repositories/AuthRepository.swift")
        XCTAssertTrue(repository.contains("catch let error as GRPCStatus where error.code == .unauthenticated {"))
        XCTAssertTrue(repository.contains("throw AppError.otpInvalid"))
    }

    // MARK: - Expiry

    func testExpiryAndResendAreSeparateClocks() async throws {
        final class StubAuth: AuthServiceProtocol, @unchecked Sendable {
            func login(phoneNumber: String) async throws -> OTPRequestResult {
                OTPRequestResult(requestId: phoneNumber, expiresInSeconds: 300, phoneNumber: phoneNumber)
            }
            func verifyOTP(phoneNumber: String, code: String, requestId: String, registrationLockPin: String?) async throws {}
            func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult { try await login(phoneNumber: phoneNumber) }
            func logout() async throws {}
            func deleteAccount() async throws {}
        }
        let vm = AuthViewModel()
        vm.country = try XCTUnwrap(PhoneCountry.withRegion("IN"))
        vm.phoneNumber = "9876543210"
        await vm.requestOTP(authService: StubAuth())
        XCTAssertEqual(vm.otpSecondsRemaining, 300, "the server's lifetime, not a clamp")
        XCTAssertEqual(vm.resendCountdown, AuthViewModel.resendCooldownSeconds, "resend cools down independently")
        XCTAssertFalse(vm.isOTPExpired)
        XCTAssertEqual(vm.formattedOTPExpiry, "5:00")
        vm.goBackToPhone()
        XCTAssertEqual(vm.otpSecondsRemaining, 0)
        XCTAssertFalse(vm.isOTPExpired, "no code outstanding means nothing to expire")
    }

    func testVerifyRefusesAnExpiredCodeBeforeTheNetwork() throws {
        let vm = AuthViewModel()
        let source = try source("Features/Auth/Presentation/AuthViewModel.swift")
        XCTAssertTrue(source.contains("guard !isOTPExpired else {"), "an expired code is refused locally")
        XCTAssertTrue(try self.source("Features/Auth/Presentation/OTPView.swift").contains("Code expires in"), "the OTP screen shows the lifetime")
        XCTAssertTrue(try self.source("Features/Auth/Presentation/OTPView.swift").contains("This code has expired"))
        _ = vm
    }

    func testCancellingTheRegistrationLockClearsTheCode() {
        let vm = AuthViewModel()
        vm.otpCode = "123456"
        vm.showRegistrationLockPIN = true
        vm.cancelRegistrationLockPIN()
        XCTAssertEqual(vm.otpCode, "", "six digits left in the boxes made the screen inert")
        XCTAssertFalse(vm.showRegistrationLockPIN)
    }

    // MARK: - Accessibility

    func testTheCodeEntryAndLoginControlsAreLabelled() throws {
        let otp = try source("Features/Auth/Presentation/OTPView.swift")
        for needle in [".accessibilityHidden(true)", ".accessibilityLabel(\"Verification code\")",
                       ".accessibilityValue(\"\\(viewModel.otpCode.count) of 6 digits entered\")",
                       ".accessibilityLabel(\"Resend code\")", ".accessibilityLabel(\"Back to phone number\")"] {
            XCTAssertTrue(otp.contains(needle), "OTPView lost `\(needle)`")
        }
        let login = try source("Features/Auth/Presentation/LoginView.swift")
        for needle in [".accessibilityLabel(\"Phone number\")", ".accessibilityLabel(\"Country, \\(viewModel.country.name) \\(viewModel.countryCode)\")",
                       "CountryPickerView(selection: $viewModel.country)"] {
            XCTAssertTrue(login.contains(needle), "LoginView lost `\(needle)`")
        }
        XCTAssertFalse(login.contains("military-grade"))
    }
}
