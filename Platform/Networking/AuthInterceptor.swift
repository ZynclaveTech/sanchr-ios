import Foundation

// TODO: Import GRPC when grpc-swift is resolved
// import GRPC

/// Interceptor that injects the JWT bearer token into every outgoing gRPC call.
/// Automatically triggers token refresh when a 401 is received.
final class AuthInterceptor: @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol

    init(secureStorage: SecureStorageProtocol) {
        self.secureStorage = secureStorage
    }

    // TODO: Conform to ClientInterceptor protocol from grpc-swift
    //
    // func send(
    //     _ part: GRPCClientRequestPart<Request>,
    //     promise: EventLoopPromise<Void>?,
    //     context: ClientInterceptorContext<Request, Response>
    // ) {
    //     switch part {
    //     case .metadata(var headers):
    //         if let token = try? secureStorage.readAccessToken() {
    //             headers.add(name: "authorization", value: "Bearer \(token)")
    //         }
    //         context.send(.metadata(headers), promise: promise)
    //     default:
    //         context.send(part, promise: promise)
    //     }
    // }
    //
    // func receive(
    //     _ part: GRPCClientResponsePart<Response>,
    //     context: ClientInterceptorContext<Request, Response>
    // ) {
    //     switch part {
    //     case .end(let status, _) where status.code == .unauthenticated:
    //         // TODO: Trigger token refresh via SessionService
    //         SanchrLogger.auth.warning("Received 401 - token refresh needed")
    //     default:
    //         break
    //     }
    //     context.receive(part)
    // }
}
