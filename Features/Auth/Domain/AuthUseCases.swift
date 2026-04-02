import Foundation

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

    /// Registers a new user account with identity key generation.
    struct RegisterUseCase: Sendable {
        private let authDataSource: AuthDataSource
        private let keyManager: KeyManagerProtocol
        private let sessionService: SessionService

        init(authDataSource: AuthDataSource, keyManager: KeyManagerProtocol, sessionService: SessionService) {
            self.authDataSource = authDataSource
            self.keyManager = keyManager
            self.sessionService = sessionService
        }

        /// Validates phone format, registers via gRPC, generates identity keys,
        /// and stores the resulting session tokens.
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

            // 2. Register via gRPC
            let tokens = try await authDataSource.register(
                phoneNumber: validPhone,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            // 3. Store session tokens
            try await sessionService.storeTokens(tokens)

            // 4. Generate and upload identity keys for Signal Protocol
            let keyPair = try await keyManager.generateIdentityKeyPair()
            let signedPreKey = try await keyManager.generateSignedPreKey()
            let oneTimePreKeys = try await keyManager.generatePreKeys(count: 100)

            // Upload pre-key bundle (best-effort; app remains functional if this fails)
            do {
                let keyClient = Vync_Keys_KeyServiceClient(grpcClient: GRPCClient(configuration: .current))
                var bundle = Vync_Keys_KeyBundle()
                bundle.identityPublicKey = keyPair.publicKey
                bundle.signedPreKey = Vync_Keys_SignedPreKey(
                    keyID: Int32(signedPreKey.id),
                    publicKey: signedPreKey.publicKey,
                    signature: signedPreKey.signature
                )
                bundle.oneTimePreKeys = oneTimePreKeys.map { key in
                    Vync_Keys_OneTimePreKey(keyID: Int32(key.id), publicKey: key.publicKey)
                }
                _ = try await keyClient.uploadKeyBundle(bundle)
            } catch {
                SanchrLogger.auth.warning("Pre-key upload failed during registration: \(error.localizedDescription)")
            }

            SanchrLogger.auth.info("RegisterUseCase: completed successfully")
            return User(
                id: tokens.userId,
                phoneNumber: validPhone,
                displayName: displayName,
                avatarURL: nil,
                bio: nil,
                isVerified: true,
                lastSeen: Date(),
                identityKeyFingerprint: nil,
                status: .online,
                isLocalUser: true
            )
        }
    }

    // MARK: - Verify OTP Use Case

    /// Verifies the OTP code, stores tokens, generates keys if needed, and returns the user.
    struct VerifyOTPUseCase: Sendable {
        private let authDataSource: AuthDataSource
        private let keyManager: KeyManagerProtocol
        private let sessionService: SessionService

        init(authDataSource: AuthDataSource, keyManager: KeyManagerProtocol, sessionService: SessionService) {
            self.authDataSource = authDataSource
            self.keyManager = keyManager
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

            // 4. Generate identity keys if this is first login on this device
            if !keyManager.hasIdentityKeys {
                SanchrLogger.auth.info("First device login — generating identity keys")
                let keyPair = try await keyManager.generateIdentityKeyPair()
                let signedPreKey = try await keyManager.generateSignedPreKey()
                let oneTimePreKeys = try await keyManager.generatePreKeys(count: 100)

                do {
                    let keyClient = Vync_Keys_KeyServiceClient(grpcClient: GRPCClient(configuration: .current))
                    var bundle = Vync_Keys_KeyBundle()
                    bundle.identityPublicKey = keyPair.publicKey
                    bundle.signedPreKey = Vync_Keys_SignedPreKey(
                        keyID: Int32(signedPreKey.id),
                        publicKey: signedPreKey.publicKey,
                        signature: signedPreKey.signature
                    )
                    bundle.oneTimePreKeys = oneTimePreKeys.map { key in
                        Vync_Keys_OneTimePreKey(keyID: Int32(key.id), publicKey: key.publicKey)
                    }
                    _ = try await keyClient.uploadKeyBundle(bundle)
                } catch {
                    SanchrLogger.auth.warning("Pre-key upload failed after OTP: \(error.localizedDescription)")
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
