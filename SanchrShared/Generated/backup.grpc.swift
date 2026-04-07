//
// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated manually to match grpc-swift client conventions for backup.proto.
// Source: backup.proto
//
import GRPC
import NIO
import SwiftProtobuf

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol Vync_Backup_BackupServiceAsyncClientProtocol: GRPCClient {
  static var serviceDescriptor: GRPCServiceDescriptor { get }
  var interceptors: Vync_Backup_BackupServiceClientInterceptorFactoryProtocol? { get }

  func makeCreateBackupUploadCall(
    _ request: Vync_Backup_CreateBackupUploadRequest,
    callOptions: CallOptions?
  ) -> GRPCAsyncUnaryCall<Vync_Backup_CreateBackupUploadRequest, Vync_Backup_CreateBackupUploadResponse>

  func makeCommitBackupCall(
    _ request: Vync_Backup_CommitBackupRequest,
    callOptions: CallOptions?
  ) -> GRPCAsyncUnaryCall<Vync_Backup_CommitBackupRequest, Vync_Backup_CommitBackupResponse>

  func makeListBackupsCall(
    _ request: Vync_Backup_ListBackupsRequest,
    callOptions: CallOptions?
  ) -> GRPCAsyncUnaryCall<Vync_Backup_ListBackupsRequest, Vync_Backup_ListBackupsResponse>

  func makeGetBackupDownloadCall(
    _ request: Vync_Backup_GetBackupDownloadRequest,
    callOptions: CallOptions?
  ) -> GRPCAsyncUnaryCall<Vync_Backup_GetBackupDownloadRequest, Vync_Backup_GetBackupDownloadResponse>

  func makeDeleteBackupCall(
    _ request: Vync_Backup_DeleteBackupRequest,
    callOptions: CallOptions?
  ) -> GRPCAsyncUnaryCall<Vync_Backup_DeleteBackupRequest, Vync_Backup_DeleteBackupResponse>
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension Vync_Backup_BackupServiceAsyncClientProtocol {
  public static var serviceDescriptor: GRPCServiceDescriptor {
    Vync_Backup_BackupServiceClientMetadata.serviceDescriptor
  }

  public var interceptors: Vync_Backup_BackupServiceClientInterceptorFactoryProtocol? {
    nil
  }

  public func makeCreateBackupUploadCall(
    _ request: Vync_Backup_CreateBackupUploadRequest,
    callOptions: CallOptions? = nil
  ) -> GRPCAsyncUnaryCall<Vync_Backup_CreateBackupUploadRequest, Vync_Backup_CreateBackupUploadResponse> {
    self.makeAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.createBackupUpload.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeCreateBackupUploadInterceptors() ?? []
    )
  }

  public func makeCommitBackupCall(
    _ request: Vync_Backup_CommitBackupRequest,
    callOptions: CallOptions? = nil
  ) -> GRPCAsyncUnaryCall<Vync_Backup_CommitBackupRequest, Vync_Backup_CommitBackupResponse> {
    self.makeAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.commitBackup.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeCommitBackupInterceptors() ?? []
    )
  }

  public func makeListBackupsCall(
    _ request: Vync_Backup_ListBackupsRequest,
    callOptions: CallOptions? = nil
  ) -> GRPCAsyncUnaryCall<Vync_Backup_ListBackupsRequest, Vync_Backup_ListBackupsResponse> {
    self.makeAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.listBackups.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeListBackupsInterceptors() ?? []
    )
  }

  public func makeGetBackupDownloadCall(
    _ request: Vync_Backup_GetBackupDownloadRequest,
    callOptions: CallOptions? = nil
  ) -> GRPCAsyncUnaryCall<Vync_Backup_GetBackupDownloadRequest, Vync_Backup_GetBackupDownloadResponse> {
    self.makeAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.getBackupDownload.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeGetBackupDownloadInterceptors() ?? []
    )
  }

  public func makeDeleteBackupCall(
    _ request: Vync_Backup_DeleteBackupRequest,
    callOptions: CallOptions? = nil
  ) -> GRPCAsyncUnaryCall<Vync_Backup_DeleteBackupRequest, Vync_Backup_DeleteBackupResponse> {
    self.makeAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.deleteBackup.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeDeleteBackupInterceptors() ?? []
    )
  }

  public func createBackupUpload(
    _ request: Vync_Backup_CreateBackupUploadRequest,
    callOptions: CallOptions? = nil
  ) async throws -> Vync_Backup_CreateBackupUploadResponse {
    try await self.performAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.createBackupUpload.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeCreateBackupUploadInterceptors() ?? []
    )
  }

  public func commitBackup(
    _ request: Vync_Backup_CommitBackupRequest,
    callOptions: CallOptions? = nil
  ) async throws -> Vync_Backup_CommitBackupResponse {
    try await self.performAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.commitBackup.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeCommitBackupInterceptors() ?? []
    )
  }

  public func listBackups(
    _ request: Vync_Backup_ListBackupsRequest,
    callOptions: CallOptions? = nil
  ) async throws -> Vync_Backup_ListBackupsResponse {
    try await self.performAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.listBackups.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeListBackupsInterceptors() ?? []
    )
  }

  public func getBackupDownload(
    _ request: Vync_Backup_GetBackupDownloadRequest,
    callOptions: CallOptions? = nil
  ) async throws -> Vync_Backup_GetBackupDownloadResponse {
    try await self.performAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.getBackupDownload.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeGetBackupDownloadInterceptors() ?? []
    )
  }

  public func deleteBackup(
    _ request: Vync_Backup_DeleteBackupRequest,
    callOptions: CallOptions? = nil
  ) async throws -> Vync_Backup_DeleteBackupResponse {
    try await self.performAsyncUnaryCall(
      path: Vync_Backup_BackupServiceClientMetadata.Methods.deleteBackup.path,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeDeleteBackupInterceptors() ?? []
    )
  }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct Vync_Backup_BackupServiceAsyncClient: Vync_Backup_BackupServiceAsyncClientProtocol {
  public var channel: GRPCChannel
  public var defaultCallOptions: CallOptions
  public var interceptors: Vync_Backup_BackupServiceClientInterceptorFactoryProtocol?

  public init(
    channel: GRPCChannel,
    defaultCallOptions: CallOptions = CallOptions(),
    interceptors: Vync_Backup_BackupServiceClientInterceptorFactoryProtocol? = nil
  ) {
    self.channel = channel
    self.defaultCallOptions = defaultCallOptions
    self.interceptors = interceptors
  }
}

public protocol Vync_Backup_BackupServiceClientInterceptorFactoryProtocol: Sendable {
  func makeCreateBackupUploadInterceptors() -> [ClientInterceptor<Vync_Backup_CreateBackupUploadRequest, Vync_Backup_CreateBackupUploadResponse>]
  func makeCommitBackupInterceptors() -> [ClientInterceptor<Vync_Backup_CommitBackupRequest, Vync_Backup_CommitBackupResponse>]
  func makeListBackupsInterceptors() -> [ClientInterceptor<Vync_Backup_ListBackupsRequest, Vync_Backup_ListBackupsResponse>]
  func makeGetBackupDownloadInterceptors() -> [ClientInterceptor<Vync_Backup_GetBackupDownloadRequest, Vync_Backup_GetBackupDownloadResponse>]
  func makeDeleteBackupInterceptors() -> [ClientInterceptor<Vync_Backup_DeleteBackupRequest, Vync_Backup_DeleteBackupResponse>]
}

public enum Vync_Backup_BackupServiceClientMetadata {
  public static let serviceDescriptor = GRPCServiceDescriptor(
    name: "BackupService",
    fullName: "vync.backup.BackupService",
    methods: [
      Methods.createBackupUpload,
      Methods.commitBackup,
      Methods.listBackups,
      Methods.getBackupDownload,
      Methods.deleteBackup,
    ]
  )

  public enum Methods {
    internal static let createBackupUpload = GRPCMethodDescriptor(
      name: "CreateBackupUpload",
      path: "/vync.backup.BackupService/CreateBackupUpload",
      type: .unary
    )

    internal static let commitBackup = GRPCMethodDescriptor(
      name: "CommitBackup",
      path: "/vync.backup.BackupService/CommitBackup",
      type: .unary
    )

    internal static let listBackups = GRPCMethodDescriptor(
      name: "ListBackups",
      path: "/vync.backup.BackupService/ListBackups",
      type: .unary
    )

    internal static let getBackupDownload = GRPCMethodDescriptor(
      name: "GetBackupDownload",
      path: "/vync.backup.BackupService/GetBackupDownload",
      type: .unary
    )

    internal static let deleteBackup = GRPCMethodDescriptor(
      name: "DeleteBackup",
      path: "/vync.backup.BackupService/DeleteBackup",
      type: .unary
    )
  }
}
