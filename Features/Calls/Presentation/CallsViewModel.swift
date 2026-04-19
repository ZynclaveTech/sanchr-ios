import AVFoundation
import Foundation
import SanchrShared

/// Model for a call history entry.
struct CallHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let contactId: String
    let contactName: String
    let timestamp: Date
    let duration: TimeInterval
    let type: CallType
    let isVideo: Bool
    let avatarURL: URL?

    init(
        id: String,
        contactId: String,
        contactName: String,
        timestamp: Date,
        duration: TimeInterval,
        type: CallType,
        isVideo: Bool,
        avatarURL: URL? = nil
    ) {
        self.id = id
        self.contactId = contactId
        self.contactName = contactName
        self.timestamp = timestamp
        self.duration = duration
        self.type = type
        self.isVideo = isVideo
        self.avatarURL = avatarURL
    }

    enum CallType: String, Equatable, Sendable {
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

    var displayName: String {
        let trimmed = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != contactId, UUID(uuidString: trimmed) == nil {
            return trimmed
        }
        return "Unknown Caller"
    }

    var searchHaystack: String {
        "\(displayName) \(contactName) \(contactId)".lowercased()
    }

    func applyingProfile(_ profile: CallHistoryPeerProfile?) -> CallHistoryEntry {
        guard let profile else { return self }
        let nextName = profile.displayName ?? displayName
        return CallHistoryEntry(
            id: id,
            contactId: contactId,
            contactName: nextName,
            timestamp: timestamp,
            duration: duration,
            type: type,
            isVideo: isVideo,
            avatarURL: profile.avatarURL ?? avatarURL
        )
    }
}

enum CallFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case missed = "Missed"
    case incoming = "Incoming"
    case outgoing = "Outgoing"
    case video = "Video"

    var id: String { rawValue }
}

struct CallHistorySection: Identifiable, Equatable, Sendable {
    enum SectionID: String, Sendable {
        case today
        case yesterday
        case earlier
    }

    let id: SectionID
    let title: String
    let entries: [CallHistoryEntry]
}

struct CallHistoryPeerProfile: Equatable, Sendable {
    let displayName: String?
    let avatarURL: URL?
}

/// View model for the call history list screen and call initiation.
@MainActor
@Observable
final class CallsViewModel {

    // MARK: - State

    var callHistory: [CallHistoryEntry] = []
    var isLoading: Bool = false
    var isLoadingContacts: Bool = false
    var errorMessage: String?
    var newCallErrorMessage: String?
    var selectedFilter: CallFilter = .all
    var searchText: String = ""
    var contactSearchText: String = ""
    var newCallContacts: [User] = []

    var missedCount: Int {
        callHistory.filter { $0.type == .missed }.count
    }

    var filteredCallHistory: [CallHistoryEntry] {
        let filteredByType = callHistory.filter { entry in
            switch selectedFilter {
            case .all:
                return true
            case .missed:
                return entry.type == .missed
            case .incoming:
                return entry.type == .incoming
            case .outgoing:
                return entry.type == .outgoing
            case .video:
                return entry.isVideo
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return filteredByType }
        return filteredByType.filter { $0.searchHaystack.contains(query) }
    }

    var groupedCallHistory: [CallHistorySection] {
        let entries = filteredCallHistory
        let today = entries.filter { Calendar.current.isDateInToday($0.timestamp) }
        let yesterday = entries.filter { Calendar.current.isDateInYesterday($0.timestamp) }
        let earlier = entries.filter {
            !Calendar.current.isDateInToday($0.timestamp)
                && !Calendar.current.isDateInYesterday($0.timestamp)
        }

        return [
            CallHistorySection(id: .today, title: "TODAY", entries: today),
            CallHistorySection(id: .yesterday, title: "YESTERDAY", entries: yesterday),
            CallHistorySection(id: .earlier, title: "EARLIER", entries: earlier),
        ]
        .filter { !$0.entries.isEmpty }
    }

    var filteredNewCallContacts: [User] {
        let query = contactSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = newCallContacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { contact in
            "\(contact.displayName) \(contact.phoneNumber) \(contact.bio ?? "")"
                .lowercased()
                .contains(query)
        }
    }

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

    func loadCallHistory(localDatabase: LocalDatabaseProtocol? = nil, showLoadingIndicator: Bool = true) async {
        if showLoadingIndicator { isLoading = true }
        errorMessage = nil
        defer { if showLoadingIndicator { isLoading = false } }

        guard let useCase = getCallHistoryUseCase else {
            SanchrLogger.calls.warning("GetCallHistory use case not configured")
            return
        }

        do {
            let entries = try await useCase.execute()
            callHistory = await enrichCallHistory(entries, localDatabase: localDatabase)
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.calls.error("Failed to load call history: \(error.localizedDescription)")
        }
    }

    func enrichCallHistory(
        _ entries: [CallHistoryEntry],
        contacts: [User],
        conversations: [Conversation]
    ) -> [CallHistoryEntry] {
        let profiles = makePeerProfiles(contacts: contacts, conversations: conversations)
        return entries.map { entry in
            entry.applyingProfile(profiles[entry.contactId])
        }
    }

    private func enrichCallHistory(
        _ entries: [CallHistoryEntry],
        localDatabase: LocalDatabaseProtocol?
    ) async -> [CallHistoryEntry] {
        guard let localDatabase else { return entries }
        let contacts = (try? await localDatabase.fetchContacts()) ?? []
        let conversations = (try? await localDatabase.fetchConversations()) ?? []
        return enrichCallHistory(entries, contacts: contacts, conversations: conversations)
    }

    func deleteEntry(_ entry: CallHistoryEntry) async {
        callHistory.removeAll { $0.id == entry.id }
        // Server-side deletion could be added here if the API supports it
    }

    func clearHistory() async {
        callHistory.removeAll()
    }

    // MARK: - New Call Contacts

    func loadNewCallContacts(
        contactRepository: ContactRepositoryProtocol,
        localDatabase: LocalDatabaseProtocol
    ) async {
        isLoadingContacts = true
        newCallErrorMessage = nil
        defer { isLoadingContacts = false }

        do {
            newCallContacts = try await contactRepository.fetchContacts()
        } catch {
            do {
                newCallContacts = try await localDatabase.fetchContacts()
            } catch {
                newCallErrorMessage = error.localizedDescription
                SanchrLogger.calls.error("Failed to load contacts for calls: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Start Calls

    /// Initiates a voice call to the specified contact.
    @discardableResult
    func startVoiceCall(contactId: String, name: String) async -> Bool {
        await startCall(contactId: contactId, name: name, isVideo: false)
    }

    /// Initiates a video call to the specified contact.
    @discardableResult
    func startVideoCall(contactId: String, name: String) async -> Bool {
        await startCall(contactId: contactId, name: name, isVideo: true)
    }

    private func startCall(contactId: String, name: String, isVideo: Bool) async -> Bool {
        errorMessage = nil
        newCallErrorMessage = nil

        // Request microphone permission if needed
        let audioStatus = AVAudioApplication.shared.recordPermission
        if audioStatus == .undetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                setStartCallError(AppError.callPermissionDenied.localizedDescription)
                return false
            }
        } else if audioStatus == .denied {
            setStartCallError(AppError.callPermissionDenied.localizedDescription)
            return false
        }

        guard let useCase = startCallUseCase else {
            SanchrLogger.calls.warning("StartCall use case not configured")
            return false
        }

        do {
            try await useCase.execute(recipientId: contactId, recipientName: name, isVideo: isVideo)
            return true
        } catch {
            setStartCallError(error.localizedDescription)
            SanchrLogger.calls.error("Failed to start call: \(error.localizedDescription)")
            return false
        }
    }

    private func setStartCallError(_ message: String) {
        errorMessage = message
        newCallErrorMessage = message
    }

    // MARK: - Profile Helpers

    private func makePeerProfiles(
        contacts: [User],
        conversations: [Conversation]
    ) -> [String: CallHistoryPeerProfile] {
        var profiles: [String: CallHistoryPeerProfile] = [:]

        for conversation in conversations {
            for participant in conversation.participants where !participant.isLocalUser {
                profiles[participant.id] = profile(for: participant)
            }
        }

        for contact in contacts {
            profiles[contact.id] = profile(for: contact)
        }

        return profiles
    }

    private func profile(for user: User) -> CallHistoryPeerProfile {
        CallHistoryPeerProfile(
            displayName: displayName(for: user),
            avatarURL: user.avatarURL
        )
    }

    private func displayName(for user: User) -> String? {
        let displayName = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty, displayName != user.id, UUID(uuidString: displayName) == nil {
            return displayName
        }

        let phoneNumber = user.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phoneNumber.isEmpty, phoneNumber != user.id {
            return phoneNumber
        }

        return nil
    }
}
