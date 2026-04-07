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

        init(callManager: CallManager, networkMonitor: NetworkMonitorProtocol) {
            self.callManager = callManager
            self.networkMonitor = networkMonitor
        }

        func execute(recipientId: String, recipientName: String, isVideo: Bool) async throws {
            // Validate network connectivity
            guard networkMonitor.isConnected else {
                throw AppError.networkUnavailable
            }

            // Check microphone permission
            let audioStatus = AVAudioApplication.shared.recordPermission
            guard audioStatus == .granted else {
                throw AppError.callPermissionDenied
            }

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

        func execute() async throws -> Vync_Calling_TurnCredentials {
            return try await callDataSource.fetchTurnCredentials()
        }
    }
}
