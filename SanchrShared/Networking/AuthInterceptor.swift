import Foundation
import GRPC
import NIOCore
import SwiftProtobuf

// MARK: - Generic Auth Interceptor

/// Interceptor that injects the JWT bearer token and device ID into every outgoing
/// gRPC call. Skips injection for unauthenticated paths. Detects UNAUTHENTICATED
/// status on responses and triggers token refresh via SessionService.
final class AuthInterceptor<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>: ClientInterceptor<Request, Response>, @unchecked Sendable {

    private let secureStorage: SecureStorageProtocol
    private let onUnauthenticated: @Sendable () -> Void

    /// gRPC method paths that do not require an authorization header.
    /// Sealed sender messages authenticate via delivery token, not JWT.
    private static var unauthenticatedPaths: Set<String> {
        [
            "/sanchr.auth.AuthService/Register",
            "/sanchr.auth.AuthService/VerifyOTP",
            "/sanchr.auth.AuthService/Login",
            "/sanchr.auth.AuthService/RefreshToken",
            "/sanchr.messaging.MessagingService/SendSealedMessage",
        ]
    }

    init(
        secureStorage: SecureStorageProtocol,
        onUnauthenticated: @escaping @Sendable () -> Void = {}
    ) {
        self.secureStorage = secureStorage
        self.onUnauthenticated = onUnauthenticated
    }

    override func send(
        _ part: GRPCClientRequestPart<Request>,
        promise: EventLoopPromise<Void>?,
        context: ClientInterceptorContext<Request, Response>
    ) {
        var part = part
        switch part {
        case .metadata(var headers):
            // Determine if this path requires auth
            let path = context.path
            let needsAuth = !Self.unauthenticatedPaths.contains(path)

            if needsAuth, let token = try? secureStorage.readAccessToken() {
                headers.add(name: "authorization", value: "Bearer \(token)")
            }

            // Always attach device ID if available
            if let deviceId = try? secureStorage.readDeviceId(), !deviceId.isEmpty {
                headers.add(name: "x-device-id", value: deviceId)
            }

            part = .metadata(headers)
            context.send(part, promise: promise)

        default:
            context.send(part, promise: promise)
        }
    }

    override func receive(
        _ part: GRPCClientResponsePart<Response>,
        context: ClientInterceptorContext<Request, Response>
    ) {
        switch part {
        case .end(let status, _) where status.code == .unauthenticated:
            SanchrLogger.auth.warning("Received UNAUTHENTICATED from \(context.path) - triggering token refresh")
            onUnauthenticated()
        default:
            break
        }
        context.receive(part)
    }
}

// MARK: - Auth Interceptor Factory

/// A single factory that conforms to all generated service interceptor factory protocols.
/// Returns an `AuthInterceptor` for every RPC method so that auth headers are always injected.
public final class AuthInterceptorFactory: @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol
    private let onUnauthenticated: @Sendable () -> Void

    public init(
        secureStorage: SecureStorageProtocol,
        onUnauthenticated: @escaping @Sendable () -> Void = {}
    ) {
        self.secureStorage = secureStorage
        self.onUnauthenticated = onUnauthenticated
    }

    /// Creates a single-element array containing the auth interceptor for a given request/response pair.
    private func makeInterceptors<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>() -> [ClientInterceptor<Req, Resp>] {
        [AuthInterceptor<Req, Resp>(secureStorage: secureStorage, onUnauthenticated: onUnauthenticated)]
    }
}

// MARK: - AuthService Interceptors

extension AuthInterceptorFactory: Sanchr_Auth_AuthServiceClientInterceptorFactoryProtocol {
    public func makeRegisterInterceptors() -> [ClientInterceptor<Sanchr_Auth_RegisterRequest, Sanchr_Auth_AuthResponse>] { makeInterceptors() }
    public func makeVerifyOTPInterceptors() -> [ClientInterceptor<Sanchr_Auth_VerifyOTPRequest, Sanchr_Auth_AuthResponse>] { makeInterceptors() }
    public func makeLoginInterceptors() -> [ClientInterceptor<Sanchr_Auth_LoginRequest, Sanchr_Auth_AuthResponse>] { makeInterceptors() }
    public func makeRefreshTokenInterceptors() -> [ClientInterceptor<Sanchr_Auth_RefreshTokenRequest, Sanchr_Auth_AuthResponse>] { makeInterceptors() }
    public func makeLogoutInterceptors() -> [ClientInterceptor<Sanchr_Auth_LogoutRequest, Sanchr_Auth_LogoutResponse>] { makeInterceptors() }
    public func makeDeleteAccountInterceptors() -> [ClientInterceptor<Sanchr_Auth_DeleteAccountRequest, Sanchr_Auth_DeleteAccountResponse>] { makeInterceptors() }
}

// MARK: - MessagingService Interceptors

extension AuthInterceptorFactory: Sanchr_Messaging_MessagingServiceClientInterceptorFactoryProtocol {
    public func makeSendMessageInterceptors() -> [ClientInterceptor<Sanchr_Messaging_SendMessageRequest, Sanchr_Messaging_SendMessageResponse>] { makeInterceptors() }
    public func makeStartDirectConversationInterceptors() -> [ClientInterceptor<Sanchr_Messaging_StartDirectConversationRequest, Sanchr_Messaging_Conversation>] { makeInterceptors() }
    public func makeMessageStreamInterceptors() -> [ClientInterceptor<Sanchr_Messaging_ClientEvent, Sanchr_Messaging_ServerEvent>] { makeInterceptors() }
    public func makeSyncMessagesInterceptors() -> [ClientInterceptor<Sanchr_Messaging_SyncRequest, Sanchr_Messaging_EncryptedEnvelope>] { makeInterceptors() }
    public func makeAckMessagesInterceptors() -> [ClientInterceptor<Sanchr_Messaging_AckMessagesRequest, Sanchr_Messaging_AckMessagesResponse>] { makeInterceptors() }
    public func makeDeleteMessageInterceptors() -> [ClientInterceptor<Sanchr_Messaging_DeleteMessageRequest, Sanchr_Messaging_DeleteMessageResponse>] { makeInterceptors() }
    public func makeEditMessageInterceptors() -> [ClientInterceptor<Sanchr_Messaging_EditMessageRequest, Sanchr_Messaging_EditMessageResponse>] { makeInterceptors() }
    public func makeSendReceiptInterceptors() -> [ClientInterceptor<Sanchr_Messaging_ReceiptRequest, Sanchr_Messaging_ReceiptResponse>] { makeInterceptors() }
    public func makeGetConversationsInterceptors() -> [ClientInterceptor<Sanchr_Messaging_GetConversationsRequest, Sanchr_Messaging_GetConversationsResponse>] { makeInterceptors() }
    public func makeSendReactionInterceptors() -> [ClientInterceptor<Sanchr_Messaging_Reaction, Sanchr_Messaging_Reaction>] { makeInterceptors() }
    public func makeGetSenderCertificateInterceptors() -> [ClientInterceptor<Sanchr_Messaging_SenderCertificateRequest, Sanchr_Messaging_SenderCertificateResponse>] { makeInterceptors() }
    public func makeGetDeliveryTokensInterceptors() -> [ClientInterceptor<Sanchr_Messaging_DeliveryTokenRequest, Sanchr_Messaging_DeliveryTokenResponse>] { makeInterceptors() }
    public func makeSendSealedMessageInterceptors() -> [ClientInterceptor<Sanchr_Messaging_SendSealedMessageRequest, Sanchr_Messaging_SendSealedMessageResponse>] { makeInterceptors() }
    public func makeDeleteConversationInterceptors() -> [ClientInterceptor<Sanchr_Messaging_DeleteConversationRequest, Sanchr_Messaging_DeleteConversationResponse>] { makeInterceptors() }
}

// MARK: - ContactService Interceptors

extension AuthInterceptorFactory: Sanchr_Contacts_ContactServiceClientInterceptorFactoryProtocol {
    public func makeSyncContactsInterceptors() -> [ClientInterceptor<Sanchr_Contacts_SyncContactsRequest, Sanchr_Contacts_SyncContactsResponse>] { makeInterceptors() }
    public func makeGetContactsInterceptors() -> [ClientInterceptor<Sanchr_Contacts_GetContactsRequest, Sanchr_Contacts_GetContactsResponse>] { makeInterceptors() }
    public func makeBlockContactInterceptors() -> [ClientInterceptor<Sanchr_Contacts_BlockContactRequest, Sanchr_Contacts_BlockContactResponse>] { makeInterceptors() }
    public func makeUnblockContactInterceptors() -> [ClientInterceptor<Sanchr_Contacts_UnblockContactRequest, Sanchr_Contacts_UnblockContactResponse>] { makeInterceptors() }
    public func makeGetBlockedListInterceptors() -> [ClientInterceptor<Sanchr_Contacts_GetBlockedListRequest, Sanchr_Contacts_GetBlockedListResponse>] { makeInterceptors() }
}

// MARK: - KeyService Interceptors

extension AuthInterceptorFactory: Sanchr_Keys_KeyServiceClientInterceptorFactoryProtocol {
    public func makeUploadKeyBundleInterceptors() -> [ClientInterceptor<Sanchr_Keys_KeyBundle, Sanchr_Keys_UploadKeyBundleResponse>] { makeInterceptors() }
    public func makeGetPreKeyBundleInterceptors() -> [ClientInterceptor<Sanchr_Keys_GetPreKeyBundleRequest, Sanchr_Keys_PreKeyBundleResponse>] { makeInterceptors() }
    public func makeUploadOneTimePreKeysInterceptors() -> [ClientInterceptor<Sanchr_Keys_UploadOneTimePreKeysRequest, Sanchr_Keys_PreKeyCountResponse>] { makeInterceptors() }
    public func makeGetPreKeyCountInterceptors() -> [ClientInterceptor<Sanchr_Keys_GetPreKeyCountRequest, Sanchr_Keys_PreKeyCountResponse>] { makeInterceptors() }
    public func makeGetUserDevicesInterceptors() -> [ClientInterceptor<Sanchr_Keys_GetUserDevicesRequest, Sanchr_Keys_GetUserDevicesResponse>] { makeInterceptors() }
}

// MARK: - MediaService Interceptors

extension AuthInterceptorFactory: Sanchr_Media_MediaServiceClientInterceptorFactoryProtocol {
    public func makeGetUploadUrlInterceptors() -> [ClientInterceptor<Sanchr_Media_GetUploadUrlRequest, Sanchr_Media_PresignedUrlResponse>] { makeInterceptors() }
    public func makeGetDownloadUrlInterceptors() -> [ClientInterceptor<Sanchr_Media_GetDownloadUrlRequest, Sanchr_Media_PresignedUrlResponse>] { makeInterceptors() }
    public func makeConfirmUploadInterceptors() -> [ClientInterceptor<Sanchr_Media_ConfirmUploadRequest, Sanchr_Media_ConfirmUploadResponse>] { makeInterceptors() }
}

// MARK: - SettingsService Interceptors

extension AuthInterceptorFactory: Sanchr_Settings_SettingsServiceClientInterceptorFactoryProtocol {
    public func makeGetSettingsInterceptors() -> [ClientInterceptor<Sanchr_Settings_GetSettingsRequest, Sanchr_Settings_UserSettings>] { makeInterceptors() }
    public func makeUpdateSettingsInterceptors() -> [ClientInterceptor<Sanchr_Settings_UpdateSettingsRequest, Sanchr_Settings_UserSettings>] { makeInterceptors() }
    public func makeUpdateProfileInterceptors() -> [ClientInterceptor<Sanchr_Settings_UpdateProfileRequest, Sanchr_Settings_ProfileResponse>] { makeInterceptors() }
    public func makeToggleSanchrModeInterceptors() -> [ClientInterceptor<Sanchr_Settings_ToggleSanchrModeRequest, Sanchr_Settings_UserSettings>] { makeInterceptors() }
    public func makeGetStorageUsageInterceptors() -> [ClientInterceptor<Sanchr_Settings_GetStorageUsageRequest, Sanchr_Settings_StorageUsageResponse>] { makeInterceptors() }
    public func makeSetRegistrationLockInterceptors() -> [ClientInterceptor<Sanchr_Settings_SetRegistrationLockRequest, Sanchr_Settings_SetRegistrationLockResponse>] { makeInterceptors() }
}

// MARK: - NotificationService Interceptors

extension AuthInterceptorFactory: Sanchr_Notifications_NotificationServiceClientInterceptorFactoryProtocol {
    public func makeRegisterPushTokenInterceptors() -> [ClientInterceptor<Sanchr_Notifications_RegisterPushTokenRequest, Sanchr_Notifications_RegisterPushTokenResponse>] { makeInterceptors() }
    public func makeUpdateNotificationPrefsInterceptors() -> [ClientInterceptor<Sanchr_Notifications_UpdateNotificationPrefsRequest, Sanchr_Notifications_UpdateNotificationPrefsResponse>] { makeInterceptors() }
    public func makeSetConversationNotificationPrefsInterceptors() -> [ClientInterceptor<Sanchr_Notifications_SetConversationNotificationPrefsRequest, Sanchr_Notifications_SetConversationNotificationPrefsResponse>] { makeInterceptors() }
}

// MARK: - VaultService Interceptors

extension AuthInterceptorFactory: Sanchr_Vault_VaultServiceClientInterceptorFactoryProtocol {
    public func makeCreateVaultItemInterceptors() -> [ClientInterceptor<Sanchr_Vault_CreateVaultItemRequest, Sanchr_Vault_VaultItem>] { makeInterceptors() }
    public func makeGetVaultItemsInterceptors() -> [ClientInterceptor<Sanchr_Vault_GetVaultItemsRequest, Sanchr_Vault_GetVaultItemsResponse>] { makeInterceptors() }
    public func makeGetVaultItemInterceptors() -> [ClientInterceptor<Sanchr_Vault_GetVaultItemRequest, Sanchr_Vault_VaultItem>] { makeInterceptors() }
    public func makeDeleteVaultItemInterceptors() -> [ClientInterceptor<Sanchr_Vault_DeleteVaultItemRequest, Sanchr_Vault_DeleteVaultItemResponse>] { makeInterceptors() }
}

// MARK: - BackupService Interceptors

extension AuthInterceptorFactory: Sanchr_Backup_BackupServiceClientInterceptorFactoryProtocol {
    public func makeCreateBackupUploadInterceptors() -> [ClientInterceptor<Sanchr_Backup_CreateBackupUploadRequest, Sanchr_Backup_CreateBackupUploadResponse>] { makeInterceptors() }
    public func makeCommitBackupInterceptors() -> [ClientInterceptor<Sanchr_Backup_CommitBackupRequest, Sanchr_Backup_CommitBackupResponse>] { makeInterceptors() }
    public func makeListBackupsInterceptors() -> [ClientInterceptor<Sanchr_Backup_ListBackupsRequest, Sanchr_Backup_ListBackupsResponse>] { makeInterceptors() }
    public func makeGetBackupDownloadInterceptors() -> [ClientInterceptor<Sanchr_Backup_GetBackupDownloadRequest, Sanchr_Backup_GetBackupDownloadResponse>] { makeInterceptors() }
    public func makeDeleteBackupInterceptors() -> [ClientInterceptor<Sanchr_Backup_DeleteBackupRequest, Sanchr_Backup_DeleteBackupResponse>] { makeInterceptors() }
}

// MARK: - DiscoveryService Interceptors

extension AuthInterceptorFactory: Sanchr_Discovery_DiscoveryServiceClientInterceptorFactoryProtocol {
    public func makeOprfDiscoverInterceptors() -> [ClientInterceptor<Sanchr_Discovery_OprfDiscoverRequest, Sanchr_Discovery_OprfDiscoverResponse>] { makeInterceptors() }
    public func makeGetBloomFilterInterceptors() -> [ClientInterceptor<Sanchr_Discovery_GetBloomFilterRequest, Sanchr_Discovery_GetBloomFilterResponse>] { makeInterceptors() }
    public func makeGetRegisteredSetInterceptors() -> [ClientInterceptor<Sanchr_Discovery_GetRegisteredSetRequest, Sanchr_Discovery_GetRegisteredSetResponse>] { makeInterceptors() }
}

// MARK: - CallSignalingService Interceptors

extension AuthInterceptorFactory: Sanchr_Calling_CallSignalingServiceClientInterceptorFactoryProtocol {
    public func makeInitiateCallInterceptors() -> [ClientInterceptor<Sanchr_Calling_CallOffer, Sanchr_Calling_CallResponse>] { makeInterceptors() }
    public func makeCallStreamInterceptors() -> [ClientInterceptor<Sanchr_Calling_CallSignal, Sanchr_Calling_CallSignal>] { makeInterceptors() }
    public func makeEndCallInterceptors() -> [ClientInterceptor<Sanchr_Calling_EndCallRequest, Sanchr_Calling_EndCallResponse>] { makeInterceptors() }
    public func makeGetCallHistoryInterceptors() -> [ClientInterceptor<Sanchr_Calling_GetCallHistoryRequest, Sanchr_Calling_GetCallHistoryResponse>] { makeInterceptors() }
    public func makeGetTurnCredentialsInterceptors() -> [ClientInterceptor<Sanchr_Calling_GetTurnCredentialsRequest, Sanchr_Calling_TurnCredentials>] { makeInterceptors() }
}
