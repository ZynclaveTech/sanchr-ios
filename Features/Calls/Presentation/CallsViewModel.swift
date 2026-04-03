import AVFoundation
import Foundation

/// Model for a call history entry.
struct CallHistoryEntry: Identifiable, Sendable {
    let id: String
    let contactId: String
    let contactName: String
    let timestamp: Date
    let duration: TimeInterval
    let type: CallType
    let isVideo: Bool

    enum CallType: String, Sendable {
        case incoming
        case outgoing
        case missed
    }

    var directionIcon: String {
        switch type {
        case .incoming: "arrow.down.left"
        case .outgoing: "arrow.up.right"
        case .missed: "phone.arrow.down.left"
        }
    }
}

/// View model for the call history list screen and call initiation.
@Observable
final class CallsViewModel {

    // MARK: - State

    var callHistory: [CallHistoryEntry] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var isInActiveCall: Bool = false
    var activeCallContactName: String = ""
    var activeCallContactId: String = ""

    // MARK: - Dependencies

    private var callManager: CallManager?
    private var getCallHistoryUseCase: CallUseCases.GetCallHistory?
    private var startCallUseCase: CallUseCases.StartCall?

    // MARK: - Configuration

    func configure(
        callManager: CallManager,
        getCallHistoryUseCase: CallUseCases.GetCallHistory,
        startCallUseCase: CallUseCases.StartCall
    ) {
        self.callManager = callManager
        self.getCallHistoryUseCase = getCallHistoryUseCase
        self.startCallUseCase = startCallUseCase
    }

    // MARK: - Call History

    func loadCallHistory() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let useCase = getCallHistoryUseCase else {
                SanchrLogger.calls.warning("GetCallHistory use case not configured")
                return
            }
            callHistory = try await useCase.execute()
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.calls.error("Failed to load call history: \(error.localizedDescription)")
        }
    }

    func deleteEntry(_ entry: CallHistoryEntry) async {
        callHistory.removeAll { $0.id == entry.id }
        // Server-side deletion could be added here if the API supports it
    }

    func clearHistory() async {
        callHistory.removeAll()
    }

    // MARK: - Start Calls

    /// Initiates a voice call to the specified contact.
    func startVoiceCall(contactId: String, name: String) async {
        await startCall(contactId: contactId, name: name, isVideo: false)
    }

    /// Initiates a video call to the specified contact.
    func startVideoCall(contactId: String, name: String) async {
        await startCall(contactId: contactId, name: name, isVideo: true)
    }

    private func startCall(contactId: String, name: String, isVideo: Bool) async {
        errorMessage = nil

        // Request microphone permission if needed
        let audioStatus = AVAudioApplication.shared.recordPermission
        if audioStatus == .undetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                errorMessage = AppError.callPermissionDenied.localizedDescription
                return
            }
        } else if audioStatus == .denied {
            errorMessage = AppError.callPermissionDenied.localizedDescription
            return
        }

        guard let useCase = startCallUseCase else {
            SanchrLogger.calls.warning("StartCall use case not configured")
            return
        }

        do {
            activeCallContactName = name
            activeCallContactId = contactId
            isInActiveCall = true
            try await useCase.execute(recipientId: contactId, recipientName: name, isVideo: isVideo)
        } catch {
            isInActiveCall = false
            errorMessage = error.localizedDescription
            SanchrLogger.calls.error("Failed to start call: \(error.localizedDescription)")
        }
    }

    // MARK: - Call State Observation

    /// Observes the CallManager's state and updates the view model accordingly.
    /// Call this from a `.task` modifier on the view.
    func observeCallState() async {
        guard let callManager else { return }

        // Poll call state changes (CallManager is @Observable, so SwiftUI will
        // react to its property changes directly when used in the view layer).
        // This method handles the transition back to idle for the view model.
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            if case .idle = callManager.callState, isInActiveCall {
                isInActiveCall = false
                activeCallContactName = ""
                activeCallContactId = ""
            }
        }
    }
}
