import Foundation

/// The server refused a sealed send as encrypted for sessions that are out of
/// date, new sessions were started, and it refused the second one too.
/// Nothing was delivered.
public struct StaleSessionsError: Error, Equatable {
    public let deviceCount: Int

    public init(deviceCount: Int) {
        self.deviceCount = deviceCount
    }
}

/// Hands a sealed send to the server, and starts over with any device the
/// server says has been set up again since the session with it was made.
///
/// A device that restores a backup or resets its keys has no sessions left.
/// Whoever was already talking to it could not know: their session still
/// encrypted, the server still accepted the result, and the recipient could
/// not read it. Nothing told the sender, so every message went the same way
/// until the recipient happened to write first.
///
/// Each message now says which registration of the device it was encrypted
/// for. The server holds the one the device publishes, compares, and when
/// they differ delivers nothing — to anyone — and names the devices. This
/// forgets those sessions, has the caller encrypt again, which starts new
/// ones from the devices' current keys, and sends once more.
///
/// Once. A second refusal is thrown as `StaleSessionsError`, never reported
/// as sent.
public struct SealedSendDispatcher: Sendable {
    public typealias Request = Sanchr_Messaging_SendSealedMessageRequest
    public typealias Response = Sanchr_Messaging_SendSealedMessageResponse
    public typealias DeviceMessage = Sanchr_Messaging_SealedDeviceMessage

    private let send: @Sendable (Request) async throws -> Response
    private let acquireToken: @Sendable () async throws -> Data
    private let registrationId: @Sendable (_ userId: String, _ deviceId: Int32) -> UInt32
    private let resetSession: @Sendable (_ userId: String, _ deviceId: Int32) throws -> Void

    public init(
        send: @escaping @Sendable (Request) async throws -> Response,
        acquireToken: @escaping @Sendable () async throws -> Data,
        registrationId: @escaping @Sendable (_ userId: String, _ deviceId: Int32) -> UInt32,
        resetSession: @escaping @Sendable (_ userId: String, _ deviceId: Int32) throws -> Void
    ) {
        self.send = send
        self.acquireToken = acquireToken
        self.registrationId = registrationId
        self.resetSession = resetSession
    }

    public init(
        grpcClient: GRPCClientProtocol,
        signalManager: SignalProtocolManagerProtocol,
        sealedSenderManager: SealedSenderManagerProtocol
    ) {
        self.init(
            send: { try await grpcClient.messagingService.sendSealedMessage($0) },
            acquireToken: { try await sealedSenderManager.acquireDeliveryToken() },
            registrationId: { signalManager.sessionRegistrationId(with: $0, deviceId: $1) },
            resetSession: { try signalManager.resetSession(with: $0, deviceId: $1) }
        )
    }

    /// Sends what `encrypt` produces. `encrypt` is called a second time if
    /// the server refuses the first, after the stale sessions are gone.
    ///
    /// Returns nil, having sent nothing and spent no token, when there is
    /// nobody to send to.
    @discardableResult
    public func dispatch(
        _ encrypt: @Sendable () async throws -> [DeviceMessage]
    ) async throws -> Response? {
        let first = try await encrypt()
        guard !first.isEmpty else { return nil }
        let refused = try await submit(first)
        guard !refused.staleDevices.isEmpty else { return refused }

        forgetStaleSessions(refused.staleDevices, sentTo: first)
        let second = try await encrypt()
        guard !second.isEmpty else {
            throw StaleSessionsError(deviceCount: refused.staleDevices.count)
        }
        let retried = try await submit(second)
        guard retried.staleDevices.isEmpty else {
            throw StaleSessionsError(deviceCount: retried.staleDevices.count)
        }
        return retried
    }

    /// One delivery token per attempt: the server spends it before it looks.
    private func submit(_ messages: [DeviceMessage]) async throws -> Response {
        var request = Request()
        request.deliveryToken = try await acquireToken()
        request.deviceMessages = messages.map { message in
            var stated = message
            // Zero when it cannot be read, which states nothing and is not
            // checked: that costs the check, never the send.
            stated.recipientRegistrationID = registrationId(message.recipientID, message.deviceID)
            return stated
        }
        return try await send(request)
    }

    /// Only a device this send was addressed to. The answer is about the
    /// request, and a server that names anything else is not given the means
    /// to reset sessions it was never asked about.
    private func forgetStaleSessions(_ stale: [Sanchr_Messaging_StaleDevice], sentTo sent: [DeviceMessage]) {
        let addressed = Set(sent.map { Address(userId: $0.recipientID, deviceId: $0.deviceID) })
        for device in stale {
            guard addressed.contains(Address(userId: device.recipientID, deviceId: device.deviceID)) else {
                SanchrLogger.crypto.warning(
                    "Server named \(device.recipientID.prefix(8)) device \(device.deviceID) as out of date, but nothing was sent to it"
                )
                continue
            }
            do {
                try resetSession(device.recipientID, device.deviceID)
                SanchrLogger.crypto.info(
                    "Session with \(device.recipientID.prefix(8)) device \(device.deviceID) is out of date (registered=\(device.registered)); starting over"
                )
            } catch {
                SanchrLogger.crypto.warning(
                    "Could not reset session with \(device.recipientID.prefix(8)) device \(device.deviceID): \(error.localizedDescription)"
                )
            }
        }
    }

    private struct Address: Hashable {
        let userId: String
        let deviceId: Int32
    }
}
