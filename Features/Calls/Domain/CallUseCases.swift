import AVFoundation
import Foundation
import SanchrShared

/// Domain use cases for call operations.
enum CallUseCases {

    // MARK: - Start Call

    /// Validates preconditions and initiates an outgoing voice or video call.
    struct StartCall: Sendable {
        private let callManager: CallManager
        private let networkMonitor: NetworkMonitorProtocol
        /// Called right before the gRPC call to sanchr-call to ensure the access
        /// token is fresh. sanchr-call validates the session on every unary RPC
        /// (unlike sanchr-core's streaming API which authenticates once at stream
        /// open), so a stale token after the app resumes from background would
        /// cause GetTurnCredentials/InitiateCall to fail with UNAUTHENTICATED.
        private let tokenRefresher: @Sendable () async throws -> Void

        init(
            callManager: CallManager,
            networkMonitor: NetworkMonitorProtocol,
            tokenRefresher: @escaping @Sendable () async throws -> Void = {}
        ) {
            self.callManager = callManager
            self.networkMonitor = networkMonitor
            self.tokenRefresher = tokenRefresher
        }

        func execute(recipientId: String, recipientName: String, isVideo: Bool) async throws {
            // Validate network connectivity
            guard networkMonitor.isConnected else {
                throw AppError.networkUnavailable
            }

            // Request microphone permission if not yet determined; deny → throw.
            let audioStatus = AVAudioApplication.shared.recordPermission
            if audioStatus == .undetermined {
                let granted = await AVAudioApplication.requestRecordPermission()
                guard granted else { throw AppError.callPermissionDenied }
            } else {
                guard audioStatus == .granted else { throw AppError.callPermissionDenied }
            }

            // For video calls, also request camera permission if needed.
            if isVideo {
                let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                if cameraStatus == .notDetermined {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    guard granted else { throw AppError.callPermissionDenied }
                } else {
                    guard cameraStatus == .authorized else { throw AppError.callPermissionDenied }
                }
            }

            // Proactively refresh the access token so sanchr-call's per-request
            // session validation never sees a stale JWT. forceRefreshToken() is
            // a no-op if a refresh is already in flight (coalesces via activeRefreshTask).
            try await tokenRefresher()

            try await callManager.startCall(
                recipientId: recipientId,
                recipientName: recipientName,
                isVideo: isVideo
            )
        }
    }

    // MARK: - Get Call History

    /// Fetches and formats call history from the server for display.
    struct GetCallHistory: Sendable {
        private let callDataSource: CallDataSource

        init(callDataSource: CallDataSource) {
            self.callDataSource = callDataSource
        }

        func execute(limit: Int32 = 50) async throws -> [CallHistoryEntry] {
            let entries = try await callDataSource.fetchCallHistory(limit: limit)
            return entries.map { entry in
                let callType: CallHistoryEntry.CallType
                if entry.status == "missed" {
                    callType = .missed
                } else if entry.direction == "incoming" {
                    callType = .incoming
                } else {
                    callType = .outgoing
                }

                return CallHistoryEntry(
                    id: entry.callID,
                    contactId: entry.peerID,
                    contactName: entry.peerName,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(entry.startedAt)),
                    duration: TimeInterval(entry.durationSecs),
                    type: callType,
                    isVideo: entry.callType == "video"
                )
            }
        }
    }

    // MARK: - Get TURN Credentials

    /// Fetches TURN server credentials for WebRTC NAT traversal.
    struct GetTurnCredentials: Sendable {
        private let callDataSource: CallDataSource

        init(callDataSource: CallDataSource) {
            self.callDataSource = callDataSource
        }

        func execute() async throws -> Sanchr_Calling_TurnCredentials {
            return try await callDataSource.fetchTurnCredentials()
        }
    }
}
