import Foundation

/// Domain use cases for authentication flows.
enum AuthUseCases {

    /// Initiates phone-number-based login by requesting an OTP.
    struct RequestOTP: Sendable {
        private let authRepository: AuthRepositoryProtocol

        init(authRepository: AuthRepositoryProtocol) {
            self.authRepository = authRepository
        }

        func execute(phoneNumber: String) async throws -> OTPRequestResult {
            // TODO: Validate phone number format before sending
            guard phoneNumber.count >= 10 else {
                throw AppError.invalidCredentials
            }
            return try await authRepository.requestOTP(phoneNumber: phoneNumber)
        }
    }

    /// Verifies an OTP code and establishes a session.
    struct VerifyOTP: Sendable {
        private let authRepository: AuthRepositoryProtocol
        private let keyManager: KeyManagerProtocol

        init(authRepository: AuthRepositoryProtocol, keyManager: KeyManagerProtocol) {
            self.authRepository = authRepository
            self.keyManager = keyManager
        }

        func execute(phoneNumber: String, code: String, requestId: String) async throws -> AuthTokens {
            let tokens = try await authRepository.verifyOTP(
                phoneNumber: phoneNumber,
                code: code,
                requestId: requestId
            )

            // Generate and upload pre-keys if this is the first login on this device
            if !keyManager.hasIdentityKeys {
                let keyPair = try await keyManager.generateIdentityKeyPair()
                let signedPreKey = try await keyManager.generateSignedPreKey()
                let oneTimePreKeys = try await keyManager.generatePreKeys(count: 100)

                try await authRepository.uploadPreKeyBundle(
                    identityKey: keyPair.publicKey,
                    signedPreKey: signedPreKey.publicKey,
                    signedPreKeySignature: signedPreKey.signature,
                    oneTimePreKeys: oneTimePreKeys.map(\.publicKey)
                )
            }

            return tokens
        }
    }

    /// Registers a new user account with identity key generation.
    struct Register: Sendable {
        private let authRepository: AuthRepositoryProtocol
        private let keyManager: KeyManagerProtocol

        init(authRepository: AuthRepositoryProtocol, keyManager: KeyManagerProtocol) {
            self.authRepository = authRepository
            self.keyManager = keyManager
        }

        func execute(phoneNumber: String, displayName: String) async throws -> AuthTokens {
            // Generate identity key pair for the new account
            let keyPair = try await keyManager.generateIdentityKeyPair()

            let tokens = try await authRepository.register(
                phoneNumber: phoneNumber,
                displayName: displayName,
                identityPublicKey: keyPair.publicKey
            )

            // Upload pre-key bundle
            let signedPreKey = try await keyManager.generateSignedPreKey()
            let oneTimePreKeys = try await keyManager.generatePreKeys(count: 100)

            try await authRepository.uploadPreKeyBundle(
                identityKey: keyPair.publicKey,
                signedPreKey: signedPreKey.publicKey,
                signedPreKeySignature: signedPreKey.signature,
                oneTimePreKeys: oneTimePreKeys.map(\.publicKey)
            )

            return tokens
        }
    }
}
