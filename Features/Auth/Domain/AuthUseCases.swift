import Foundation
import LibSignalClient

/// Domain use cases for authentication flows.
/// Each use case encapsulates a single auth operation with validation.
enum AuthUseCases {

    // MARK: - Phone Validation Helper

    /// Validates an E.164 phone number format.
    /// Returns the cleaned number or throws on invalid input.
    static func validatePhoneNumber(_ phone: String) throws -> String {
        let cleaned = phone.replacingOccurrences(of: "[^+0-9]", with: "", options: .regularExpression)

        // Must start with + and contain at least 10 digits (including country code)
        guard cleaned.hasPrefix("+"), cleaned.count >= 11, cleaned.count <= 16 else {
            SanchrLogger.auth.warning("Phone validation failed: \(phone.prefix(4))****")
            throw AppError.invalidCredentials
        }

        // Ensure remaining characters are digits
        let digitsOnly = cleaned.dropFirst()
        guard digitsOnly.allSatisfy(\.isNumber) else {
            throw AppError.invalidCredentials
        }

        return cleaned
    }

    // MARK: - Register Use Case

    /// Registers a new user account with Signal Protocol identity key generation.
    struct RegisterUseCase: Sendable {
        private let authDataSource: AuthDataSource
        private let signalKeyManager: SignalKeyManager
        private let sessionService: SessionService

        init(authDataSource: AuthDataSource, signalKeyManager: SignalKeyManager, sessionService: SessionService) {
            self.authDataSource = authDataSource
            self.signalKeyManager = signalKeyManager
            self.sessionService = sessionService
        }

        /// Validates phone format, registers via gRPC, generates Signal Protocol identity keys,
        /// and uploads the full key bundle to the server.
        func execute(phoneNumber: String, displayName: String) async throws -> User {
            // 1. Validate inputs
            let validPhone = try AuthUseCases.validatePhoneNumber(phoneNumber)

            guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.registrationFailed(reason: "Display name cannot be empty.")
            }

            guard displayName.count <= 64 else {
                throw AppError.registrationFailed(reason: "Display name is too long.")
            }

            SanchrLogger.auth.info("RegisterUseCase: executing for \(validPhone.prefix(4))****")

            // 2. Generate Signal Protocol identity key pair
            let identityKeyPair = try signalKeyManager.generateIdentityIfNeeded()

            // 3. Register via gRPC (send identity public key with registration)
            let tokens = try await authDataSource.register(
                phoneNumber: validPhone,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            // 4. Store session tokens
            try await sessionService.storeTokens(tokens)

            // 5. Upload full Signal Protocol key bundle to server
            do {
                try await signalKeyManager.uploadInitialKeyBundle()
            } catch {
                SanchrLogger.auth.warning("Key bundle upload failed during registration: \(error.localizedDescription)")
                // Non-fatal: the app can retry later via checkAndReplenishPreKeys.
            }

            // 6. Compute identity key fingerprint for display
            let identityFingerprint = Data(identityKeyPair.identityKey.serialize())
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined(separator: " ")

            SanchrLogger.auth.info("RegisterUseCase: completed successfully")
            return User(
                id: tokens.userId,
                phoneNumber: validPhone,
                displayName: displayName,
                avatarURL: nil,
                bio: nil,
                isVerified: true,
                lastSeen: Date(),
                identityKeyFingerprint: identityFingerprint,
                status: .online,
                isLocalUser: true
            )
        }
    }

    // MARK: - Verify OTP Use Case

    /// Verifies the OTP code, stores tokens, generates Signal Protocol keys if needed,
    /// and uploads the key bundle to the server.
    struct VerifyOTPUseCase: Sendable {
        private let authDataSource: AuthDataSource
        private let signalKeyManager: SignalKeyManager
        private let sessionService: SessionService

        init(authDataSource: AuthDataSource, signalKeyManager: SignalKeyManager, sessionService: SessionService) {
            self.authDataSource = authDataSource
            self.signalKeyManager = signalKeyManager
            self.sessionService = sessionService
        }

        func execute(phoneNumber: String, otpCode: String) async throws -> AuthTokens {
            // 1. Validate OTP format (exactly 6 digits)
            let cleanCode = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanCode.count == 6, cleanCode.allSatisfy(\.isNumber) else {
                throw AppError.otpInvalid
            }

            let validPhone = try AuthUseCases.validatePhoneNumber(phoneNumber)

            SanchrLogger.auth.info("VerifyOTPUseCase: verifying for \(validPhone.prefix(4))****")

            // 2. Verify via gRPC
            let tokens = try await authDataSource.verifyOTP(
                phoneNumber: validPhone,
                otpCode: cleanCode
            )

            // 3. Store tokens
            try await sessionService.storeTokens(tokens)

            // 4. Generate Signal Protocol identity keys if this is first login on this device
            if !signalKeyManager.hasIdentityKeys {
                SanchrLogger.auth.info("First device login -- generating Signal Protocol identity keys")

                // Generate identity key pair (stored in Keychain)
                _ = try signalKeyManager.generateIdentityIfNeeded()

                // Upload the full key bundle: identity key + signed pre-key + 100 one-time pre-keys
                do {
                    try await signalKeyManager.uploadInitialKeyBundle()
                    SanchrLogger.auth.info("Signal Protocol key bundle uploaded successfully")
                } catch {
                    SanchrLogger.auth.warning("Key bundle upload failed after OTP: \(error.localizedDescription)")
                    // Non-fatal: will be retried when a PreKeyCountLow server event arrives.
                }
            } else {
                // Keys exist; check if the server needs more one-time pre-keys.
                do {
                    try await signalKeyManager.checkAndReplenishPreKeys(threshold: 25)
                } catch {
                    SanchrLogger.auth.warning("Pre-key replenishment check failed: \(error.localizedDescription)")
                }
            }

            SanchrLogger.auth.info("VerifyOTPUseCase: completed successfully")
            return tokens
        }
    }

    // MARK: - Login Use Case

    /// Validates inputs, calls the login gRPC endpoint, and stores the session.
    struct LoginUseCase: Sendable {
        private let authDataSource: AuthDataSource
        private let sessionService: SessionService

        init(authDataSource: AuthDataSource, sessionService: SessionService) {
            self.authDataSource = authDataSource
            self.sessionService = sessionService
        }

        /// Initiates login. The server will send an OTP to the phone number.
        /// Returns auth tokens after successful authentication.
        func execute(phoneNumber: String, password: String = "") async throws -> AuthTokens {
            let validPhone = try AuthUseCases.validatePhoneNumber(phoneNumber)

            SanchrLogger.auth.info("LoginUseCase: executing for \(validPhone.prefix(4))****")

            let tokens = try await authDataSource.login(
                phoneNumber: validPhone,
                password: password
            )

            try await sessionService.storeTokens(tokens)

            SanchrLogger.auth.info("LoginUseCase: session stored successfully")
            return tokens
        }
    }
}
