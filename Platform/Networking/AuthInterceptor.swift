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
    private static var unauthenticatedPaths: Set<String> {
        [
            "/vync.auth.AuthService/Register",
            "/vync.auth.AuthService/VerifyOTP",
            "/vync.auth.AuthService/Login",
            "/vync.auth.AuthService/RefreshToken",
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
final class AuthInterceptorFactory: @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol
    private let onUnauthenticated: @Sendable () -> Void

    init(
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

extension AuthInterceptorFactory: Vync_Auth_AuthServiceClientInterceptorFactoryProtocol {
    func makeRegisterInterceptors() -> [ClientInterceptor<Vync_Auth_RegisterRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    func makeVerifyOTPInterceptors() -> [ClientInterceptor<Vync_Auth_VerifyOTPRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    func makeLoginInterceptors() -> [ClientInterceptor<Vync_Auth_LoginRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    func makeRefreshTokenInterceptors() -> [ClientInterceptor<Vync_Auth_RefreshTokenRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    func makeLogoutInterceptors() -> [ClientInterceptor<Vync_Auth_LogoutRequest, Vync_Auth_LogoutResponse>] { makeInterceptors() }
    func makeChangePasswordInterceptors() -> [ClientInterceptor<Vync_Auth_ChangePasswordRequest, Vync_Auth_ChangePasswordResponse>] { makeInterceptors() }
}

// MARK: - MessagingService Interceptors

extension AuthInterceptorFactory: Vync_Messaging_MessagingServiceClientInterceptorFactoryProtocol {
    func makeSendMessageInterceptors() -> [ClientInterceptor<Vync_Messaging_SendMessageRequest, Vync_Messaging_SendMessageResponse>] { makeInterceptors() }
    func makeStartDirectConversationInterceptors() -> [ClientInterceptor<Vync_Messaging_StartDirectConversationRequest, Vync_Messaging_Conversation>] { makeInterceptors() }
    func makeMessageStreamInterceptors() -> [ClientInterceptor<Vync_Messaging_ClientEvent, Vync_Messaging_ServerEvent>] { makeInterceptors() }
    func makeSyncMessagesInterceptors() -> [ClientInterceptor<Vync_Messaging_SyncRequest, Vync_Messaging_EncryptedEnvelope>] { makeInterceptors() }
    func makeAckMessagesInterceptors() -> [ClientInterceptor<Vync_Messaging_AckMessagesRequest, Vync_Messaging_AckMessagesResponse>] { makeInterceptors() }
    func makeDeleteMessageInterceptors() -> [ClientInterceptor<Vync_Messaging_DeleteMessageRequest, Vync_Messaging_DeleteMessageResponse>] { makeInterceptors() }
    func makeSendReceiptInterceptors() -> [ClientInterceptor<Vync_Messaging_ReceiptRequest, Vync_Messaging_ReceiptResponse>] { makeInterceptors() }
    func makeGetConversationsInterceptors() -> [ClientInterceptor<Vync_Messaging_GetConversationsRequest, Vync_Messaging_GetConversationsResponse>] { makeInterceptors() }
    func makeGetPresenceSnapshotInterceptors() -> [ClientInterceptor<Vync_Messaging_GetPresenceSnapshotRequest, Vync_Messaging_GetPresenceSnapshotResponse>] { makeInterceptors() }
}

// MARK: - ContactService Interceptors

extension AuthInterceptorFactory: Vync_Contacts_ContactServiceClientInterceptorFactoryProtocol {
    func makeSyncContactsInterceptors() -> [ClientInterceptor<Vync_Contacts_SyncContactsRequest, Vync_Contacts_SyncContactsResponse>] { makeInterceptors() }
    func makeGetContactsInterceptors() -> [ClientInterceptor<Vync_Contacts_GetContactsRequest, Vync_Contacts_GetContactsResponse>] { makeInterceptors() }
    func makeBlockContactInterceptors() -> [ClientInterceptor<Vync_Contacts_BlockContactRequest, Vync_Contacts_BlockContactResponse>] { makeInterceptors() }
    func makeUnblockContactInterceptors() -> [ClientInterceptor<Vync_Contacts_UnblockContactRequest, Vync_Contacts_UnblockContactResponse>] { makeInterceptors() }
    func makeGetBlockedListInterceptors() -> [ClientInterceptor<Vync_Contacts_GetBlockedListRequest, Vync_Contacts_GetBlockedListResponse>] { makeInterceptors() }
}

// MARK: - KeyService Interceptors

extension AuthInterceptorFactory: Vync_Keys_KeyServiceClientInterceptorFactoryProtocol {
    func makeUploadKeyBundleInterceptors() -> [ClientInterceptor<Vync_Keys_KeyBundle, Vync_Keys_UploadKeyBundleResponse>] { makeInterceptors() }
    func makeGetPreKeyBundleInterceptors() -> [ClientInterceptor<Vync_Keys_GetPreKeyBundleRequest, Vync_Keys_PreKeyBundleResponse>] { makeInterceptors() }
    func makeUploadOneTimePreKeysInterceptors() -> [ClientInterceptor<Vync_Keys_UploadOneTimePreKeysRequest, Vync_Keys_PreKeyCountResponse>] { makeInterceptors() }
    func makeGetPreKeyCountInterceptors() -> [ClientInterceptor<Vync_Keys_GetPreKeyCountRequest, Vync_Keys_PreKeyCountResponse>] { makeInterceptors() }
    func makeGetUserDevicesInterceptors() -> [ClientInterceptor<Vync_Keys_GetUserDevicesRequest, Vync_Keys_GetUserDevicesResponse>] { makeInterceptors() }
}

// MARK: - MediaService Interceptors

extension AuthInterceptorFactory: Vync_Media_MediaServiceClientInterceptorFactoryProtocol {
    func makeGetUploadUrlInterceptors() -> [ClientInterceptor<Vync_Media_GetUploadUrlRequest, Vync_Media_PresignedUrlResponse>] { makeInterceptors() }
    func makeGetDownloadUrlInterceptors() -> [ClientInterceptor<Vync_Media_GetDownloadUrlRequest, Vync_Media_PresignedUrlResponse>] { makeInterceptors() }
    func makeConfirmUploadInterceptors() -> [ClientInterceptor<Vync_Media_ConfirmUploadRequest, Vync_Media_ConfirmUploadResponse>] { makeInterceptors() }
}

// MARK: - SettingsService Interceptors

extension AuthInterceptorFactory: Vync_Settings_SettingsServiceClientInterceptorFactoryProtocol {
    func makeGetSettingsInterceptors() -> [ClientInterceptor<Vync_Settings_GetSettingsRequest, Vync_Settings_UserSettings>] { makeInterceptors() }
    func makeUpdateSettingsInterceptors() -> [ClientInterceptor<Vync_Settings_UpdateSettingsRequest, Vync_Settings_UserSettings>] { makeInterceptors() }
    func makeUpdateProfileInterceptors() -> [ClientInterceptor<Vync_Settings_UpdateProfileRequest, Vync_Settings_ProfileResponse>] { makeInterceptors() }
    func makeToggleVyncModeInterceptors() -> [ClientInterceptor<Vync_Settings_ToggleVyncModeRequest, Vync_Settings_UserSettings>] { makeInterceptors() }
    func makeGetStorageUsageInterceptors() -> [ClientInterceptor<Vync_Settings_GetStorageUsageRequest, Vync_Settings_StorageUsageResponse>] { makeInterceptors() }
}

// MARK: - NotificationService Interceptors

extension AuthInterceptorFactory: Vync_Notifications_NotificationServiceClientInterceptorFactoryProtocol {
    func makeRegisterPushTokenInterceptors() -> [ClientInterceptor<Vync_Notifications_RegisterPushTokenRequest, Vync_Notifications_RegisterPushTokenResponse>] { makeInterceptors() }
    func makeUpdateNotificationPrefsInterceptors() -> [ClientInterceptor<Vync_Notifications_UpdateNotificationPrefsRequest, Vync_Notifications_UpdateNotificationPrefsResponse>] { makeInterceptors() }
}

// MARK: - VaultService Interceptors

extension AuthInterceptorFactory: Vync_Vault_VaultServiceClientInterceptorFactoryProtocol {
    func makeGetVaultItemsInterceptors() -> [ClientInterceptor<Vync_Vault_GetVaultItemsRequest, Vync_Vault_GetVaultItemsResponse>] { makeInterceptors() }
    func makeCreateVaultItemInterceptors() -> [ClientInterceptor<Vync_Vault_CreateVaultItemRequest, Vync_Vault_VaultItem>] { makeInterceptors() }
    func makeDeleteVaultItemInterceptors() -> [ClientInterceptor<Vync_Vault_DeleteVaultItemRequest, Vync_Vault_DeleteVaultItemResponse>] { makeInterceptors() }
    func makeShareVaultItemInterceptors() -> [ClientInterceptor<Vync_Vault_ShareVaultItemRequest, Vync_Vault_ShareVaultItemResponse>] { makeInterceptors() }
}

// MARK: - BackupService Interceptors

extension AuthInterceptorFactory: Vync_Backup_BackupServiceClientInterceptorFactoryProtocol {
    func makeCreateBackupUploadInterceptors() -> [ClientInterceptor<Vync_Backup_CreateBackupUploadRequest, Vync_Backup_CreateBackupUploadResponse>] { makeInterceptors() }
    func makeCommitBackupInterceptors() -> [ClientInterceptor<Vync_Backup_CommitBackupRequest, Vync_Backup_CommitBackupResponse>] { makeInterceptors() }
    func makeListBackupsInterceptors() -> [ClientInterceptor<Vync_Backup_ListBackupsRequest, Vync_Backup_ListBackupsResponse>] { makeInterceptors() }
    func makeGetBackupDownloadInterceptors() -> [ClientInterceptor<Vync_Backup_GetBackupDownloadRequest, Vync_Backup_GetBackupDownloadResponse>] { makeInterceptors() }
    func makeDeleteBackupInterceptors() -> [ClientInterceptor<Vync_Backup_DeleteBackupRequest, Vync_Backup_DeleteBackupResponse>] { makeInterceptors() }
}

// MARK: - CallSignalingService Interceptors

extension AuthInterceptorFactory: Vync_Calling_CallSignalingServiceClientInterceptorFactoryProtocol {
    func makeInitiateCallInterceptors() -> [ClientInterceptor<Vync_Calling_CallOffer, Vync_Calling_CallResponse>] { makeInterceptors() }
    func makeCallStreamInterceptors() -> [ClientInterceptor<Vync_Calling_CallSignal, Vync_Calling_CallSignal>] { makeInterceptors() }
    func makeEndCallInterceptors() -> [ClientInterceptor<Vync_Calling_EndCallRequest, Vync_Calling_EndCallResponse>] { makeInterceptors() }
    func makeGetCallHistoryInterceptors() -> [ClientInterceptor<Vync_Calling_GetCallHistoryRequest, Vync_Calling_GetCallHistoryResponse>] { makeInterceptors() }
    func makeGetTurnCredentialsInterceptors() -> [ClientInterceptor<Vync_Calling_GetTurnCredentialsRequest, Vync_Calling_TurnCredentials>] { makeInterceptors() }
}
