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

extension AuthInterceptorFactory: Vync_Auth_AuthServiceClientInterceptorFactoryProtocol {
    public func makeRegisterInterceptors() -> [ClientInterceptor<Vync_Auth_RegisterRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    public func makeVerifyOTPInterceptors() -> [ClientInterceptor<Vync_Auth_VerifyOTPRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    public func makeLoginInterceptors() -> [ClientInterceptor<Vync_Auth_LoginRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    public func makeRefreshTokenInterceptors() -> [ClientInterceptor<Vync_Auth_RefreshTokenRequest, Vync_Auth_AuthResponse>] { makeInterceptors() }
    public func makeLogoutInterceptors() -> [ClientInterceptor<Vync_Auth_LogoutRequest, Vync_Auth_LogoutResponse>] { makeInterceptors() }
    public func makeChangePasswordInterceptors() -> [ClientInterceptor<Vync_Auth_ChangePasswordRequest, Vync_Auth_ChangePasswordResponse>] { makeInterceptors() }
    public func makeDeleteAccountInterceptors() -> [ClientInterceptor<Vync_Auth_DeleteAccountRequest, Vync_Auth_DeleteAccountResponse>] { makeInterceptors() }
}

// MARK: - MessagingService Interceptors

extension AuthInterceptorFactory: Vync_Messaging_MessagingServiceClientInterceptorFactoryProtocol {
    public func makeSendMessageInterceptors() -> [ClientInterceptor<Vync_Messaging_SendMessageRequest, Vync_Messaging_SendMessageResponse>] { makeInterceptors() }
    public func makeStartDirectConversationInterceptors() -> [ClientInterceptor<Vync_Messaging_StartDirectConversationRequest, Vync_Messaging_Conversation>] { makeInterceptors() }
    public func makeMessageStreamInterceptors() -> [ClientInterceptor<Vync_Messaging_ClientEvent, Vync_Messaging_ServerEvent>] { makeInterceptors() }
    public func makeSyncMessagesInterceptors() -> [ClientInterceptor<Vync_Messaging_SyncRequest, Vync_Messaging_EncryptedEnvelope>] { makeInterceptors() }
    public func makeAckMessagesInterceptors() -> [ClientInterceptor<Vync_Messaging_AckMessagesRequest, Vync_Messaging_AckMessagesResponse>] { makeInterceptors() }
    public func makeDeleteMessageInterceptors() -> [ClientInterceptor<Vync_Messaging_DeleteMessageRequest, Vync_Messaging_DeleteMessageResponse>] { makeInterceptors() }
    public func makeSendReceiptInterceptors() -> [ClientInterceptor<Vync_Messaging_ReceiptRequest, Vync_Messaging_ReceiptResponse>] { makeInterceptors() }
    public func makeGetConversationsInterceptors() -> [ClientInterceptor<Vync_Messaging_GetConversationsRequest, Vync_Messaging_GetConversationsResponse>] { makeInterceptors() }
    public func makeGetPresenceSnapshotInterceptors() -> [ClientInterceptor<Vync_Messaging_GetPresenceSnapshotRequest, Vync_Messaging_GetPresenceSnapshotResponse>] { makeInterceptors() }
}

// MARK: - ContactService Interceptors

extension AuthInterceptorFactory: Vync_Contacts_ContactServiceClientInterceptorFactoryProtocol {
    public func makeSyncContactsInterceptors() -> [ClientInterceptor<Vync_Contacts_SyncContactsRequest, Vync_Contacts_SyncContactsResponse>] { makeInterceptors() }
    public func makeGetContactsInterceptors() -> [ClientInterceptor<Vync_Contacts_GetContactsRequest, Vync_Contacts_GetContactsResponse>] { makeInterceptors() }
    public func makeBlockContactInterceptors() -> [ClientInterceptor<Vync_Contacts_BlockContactRequest, Vync_Contacts_BlockContactResponse>] { makeInterceptors() }
    public func makeUnblockContactInterceptors() -> [ClientInterceptor<Vync_Contacts_UnblockContactRequest, Vync_Contacts_UnblockContactResponse>] { makeInterceptors() }
    public func makeGetBlockedListInterceptors() -> [ClientInterceptor<Vync_Contacts_GetBlockedListRequest, Vync_Contacts_GetBlockedListResponse>] { makeInterceptors() }
}

// MARK: - KeyService Interceptors

extension AuthInterceptorFactory: Vync_Keys_KeyServiceClientInterceptorFactoryProtocol {
    public func makeUploadKeyBundleInterceptors() -> [ClientInterceptor<Vync_Keys_KeyBundle, Vync_Keys_UploadKeyBundleResponse>] { makeInterceptors() }
    public func makeGetPreKeyBundleInterceptors() -> [ClientInterceptor<Vync_Keys_GetPreKeyBundleRequest, Vync_Keys_PreKeyBundleResponse>] { makeInterceptors() }
    public func makeUploadOneTimePreKeysInterceptors() -> [ClientInterceptor<Vync_Keys_UploadOneTimePreKeysRequest, Vync_Keys_PreKeyCountResponse>] { makeInterceptors() }
    public func makeGetPreKeyCountInterceptors() -> [ClientInterceptor<Vync_Keys_GetPreKeyCountRequest, Vync_Keys_PreKeyCountResponse>] { makeInterceptors() }
    public func makeGetUserDevicesInterceptors() -> [ClientInterceptor<Vync_Keys_GetUserDevicesRequest, Vync_Keys_GetUserDevicesResponse>] { makeInterceptors() }
}

// MARK: - MediaService Interceptors

extension AuthInterceptorFactory: Vync_Media_MediaServiceClientInterceptorFactoryProtocol {
    public func makeGetUploadUrlInterceptors() -> [ClientInterceptor<Vync_Media_GetUploadUrlRequest, Vync_Media_PresignedUrlResponse>] { makeInterceptors() }
    public func makeGetDownloadUrlInterceptors() -> [ClientInterceptor<Vync_Media_GetDownloadUrlRequest, Vync_Media_PresignedUrlResponse>] { makeInterceptors() }
    public func makeConfirmUploadInterceptors() -> [ClientInterceptor<Vync_Media_ConfirmUploadRequest, Vync_Media_ConfirmUploadResponse>] { makeInterceptors() }
}

// MARK: - SettingsService Interceptors

extension AuthInterceptorFactory: Vync_Settings_SettingsServiceClientInterceptorFactoryProtocol {
    public func makeGetSettingsInterceptors() -> [ClientInterceptor<Vync_Settings_GetSettingsRequest, Vync_Settings_UserSettings>] { makeInterceptors() }
    public func makeUpdateSettingsInterceptors() -> [ClientInterceptor<Vync_Settings_UpdateSettingsRequest, Vync_Settings_UserSettings>] { makeInterceptors() }
    public func makeUpdateProfileInterceptors() -> [ClientInterceptor<Vync_Settings_UpdateProfileRequest, Vync_Settings_ProfileResponse>] { makeInterceptors() }
    public func makeToggleVyncModeInterceptors() -> [ClientInterceptor<Vync_Settings_ToggleVyncModeRequest, Vync_Settings_UserSettings>] { makeInterceptors() }
    public func makeGetStorageUsageInterceptors() -> [ClientInterceptor<Vync_Settings_GetStorageUsageRequest, Vync_Settings_StorageUsageResponse>] { makeInterceptors() }
}

// MARK: - NotificationService Interceptors

extension AuthInterceptorFactory: Vync_Notifications_NotificationServiceClientInterceptorFactoryProtocol {
    public func makeRegisterPushTokenInterceptors() -> [ClientInterceptor<Vync_Notifications_RegisterPushTokenRequest, Vync_Notifications_RegisterPushTokenResponse>] { makeInterceptors() }
    public func makeUpdateNotificationPrefsInterceptors() -> [ClientInterceptor<Vync_Notifications_UpdateNotificationPrefsRequest, Vync_Notifications_UpdateNotificationPrefsResponse>] { makeInterceptors() }
}

// MARK: - VaultService Interceptors

extension AuthInterceptorFactory: Vync_Vault_VaultServiceClientInterceptorFactoryProtocol {
    public func makeGetVaultItemsInterceptors() -> [ClientInterceptor<Vync_Vault_GetVaultItemsRequest, Vync_Vault_GetVaultItemsResponse>] { makeInterceptors() }
    public func makeCreateVaultItemInterceptors() -> [ClientInterceptor<Vync_Vault_CreateVaultItemRequest, Vync_Vault_VaultItem>] { makeInterceptors() }
    public func makeDeleteVaultItemInterceptors() -> [ClientInterceptor<Vync_Vault_DeleteVaultItemRequest, Vync_Vault_DeleteVaultItemResponse>] { makeInterceptors() }
    public func makeShareVaultItemInterceptors() -> [ClientInterceptor<Vync_Vault_ShareVaultItemRequest, Vync_Vault_ShareVaultItemResponse>] { makeInterceptors() }
}

// MARK: - BackupService Interceptors

extension AuthInterceptorFactory: Vync_Backup_BackupServiceClientInterceptorFactoryProtocol {
    public func makeCreateBackupUploadInterceptors() -> [ClientInterceptor<Vync_Backup_CreateBackupUploadRequest, Vync_Backup_CreateBackupUploadResponse>] { makeInterceptors() }
    public func makeCommitBackupInterceptors() -> [ClientInterceptor<Vync_Backup_CommitBackupRequest, Vync_Backup_CommitBackupResponse>] { makeInterceptors() }
    public func makeListBackupsInterceptors() -> [ClientInterceptor<Vync_Backup_ListBackupsRequest, Vync_Backup_ListBackupsResponse>] { makeInterceptors() }
    public func makeGetBackupDownloadInterceptors() -> [ClientInterceptor<Vync_Backup_GetBackupDownloadRequest, Vync_Backup_GetBackupDownloadResponse>] { makeInterceptors() }
    public func makeDeleteBackupInterceptors() -> [ClientInterceptor<Vync_Backup_DeleteBackupRequest, Vync_Backup_DeleteBackupResponse>] { makeInterceptors() }
}

// MARK: - DiscoveryService Interceptors

extension AuthInterceptorFactory: Vync_Discovery_DiscoveryServiceClientInterceptorFactoryProtocol {
    public func makeOprfDiscoverInterceptors() -> [ClientInterceptor<Vync_Discovery_OprfDiscoverRequest, Vync_Discovery_OprfDiscoverResponse>] { makeInterceptors() }
    public func makeGetBloomFilterInterceptors() -> [ClientInterceptor<Vync_Discovery_GetBloomFilterRequest, Vync_Discovery_GetBloomFilterResponse>] { makeInterceptors() }
    public func makeGetRegisteredSetInterceptors() -> [ClientInterceptor<Vync_Discovery_GetRegisteredSetRequest, Vync_Discovery_GetRegisteredSetResponse>] { makeInterceptors() }
}

// MARK: - CallSignalingService Interceptors

extension AuthInterceptorFactory: Vync_Calling_CallSignalingServiceClientInterceptorFactoryProtocol {
    public func makeInitiateCallInterceptors() -> [ClientInterceptor<Vync_Calling_CallOffer, Vync_Calling_CallResponse>] { makeInterceptors() }
    public func makeCallStreamInterceptors() -> [ClientInterceptor<Vync_Calling_CallSignal, Vync_Calling_CallSignal>] { makeInterceptors() }
    public func makeEndCallInterceptors() -> [ClientInterceptor<Vync_Calling_EndCallRequest, Vync_Calling_EndCallResponse>] { makeInterceptors() }
    public func makeGetCallHistoryInterceptors() -> [ClientInterceptor<Vync_Calling_GetCallHistoryRequest, Vync_Calling_GetCallHistoryResponse>] { makeInterceptors() }
    public func makeGetTurnCredentialsInterceptors() -> [ClientInterceptor<Vync_Calling_GetTurnCredentialsRequest, Vync_Calling_TurnCredentials>] { makeInterceptors() }
}
