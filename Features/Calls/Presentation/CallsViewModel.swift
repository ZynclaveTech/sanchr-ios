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

/// View model for the call history list screen.
@Observable
final class CallsViewModel {
    var callHistory: [CallHistoryEntry] = []
    var isLoading: Bool = false
    var errorMessage: String?

    func loadCallHistory() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: Fetch call history from local database / server
        // callHistory = try await callRepository.fetchCallHistory()
    }

    func deleteEntry(_ entry: CallHistoryEntry) async {
        callHistory.removeAll { $0.id == entry.id }
        // TODO: Delete from persistence
    }

    func clearHistory() async {
        callHistory.removeAll()
        // TODO: Clear from persistence
    }
}
