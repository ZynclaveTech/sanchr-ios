import Foundation
import SanchrShared

struct ContactSection: Identifiable, Sendable {
    let id: String
    let letter: String
    let contacts: [User]
}

/// View model for the contacts list screen.
/// Manages contacts grouped alphabetically with search, filter, block/unblock, and pull-to-refresh.
@MainActor
@Observable
final class ContactsViewModel {

    // MARK: - State

    var contacts: [User] = [] {
        didSet { rebuildDerivedState() }
    }
    var blockedUserIDs: Set<String> = [] {
        didSet { rebuildDerivedState() }
    }
    var isLoading: Bool = false
    var errorMessage: String?
    var hasCompletedSync: Bool = false
    var searchText: String = "" {
        didSet { rebuildDerivedState() }
    }

    private(set) var groupedContacts: [ContactSection] = []
    private(set) var onlineCount: Int = 0

    init() {
        rebuildDerivedState()
    }

    // MARK: - Derived State

    private func rebuildDerivedState() {
        let base = contacts.filter { !blockedUserIDs.contains($0.id) }
        onlineCount = contacts.filter { $0.status == .online }.count

        let filteredContacts: [User]
        if searchText.isEmpty {
            filteredContacts = base
        } else {
            filteredContacts = base.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        let sorted = filteredContacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sorted) { user -> String in
            let first = user.displayName.prefix(1).uppercased()
            return first.rangeOfCharacter(from: .letters) != nil ? first : "#"
        }

        groupedContacts =
            grouped
            .sorted { $0.key < $1.key }
            .map { ContactSection(id: $0.key, letter: $0.key, contacts: $0.value) }
    }

    // MARK: - Load Contacts

    func loadContacts(contactDataSource: ContactDataSource, localDatabase: LocalDatabaseProtocol)
        async
    {
        isLoading = true
        defer { isLoading = false }

        let getContacts = ContactUseCases.GetContacts(
            contactDataSource: contactDataSource,
            localDatabase: localDatabase
        )

        do {
            contacts = try await getContacts.execute()
            hasCompletedSync = !contacts.isEmpty
            errorMessage = nil
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    // MARK: - Refresh

    func refreshContacts(contactDataSource: ContactDataSource, localDatabase: LocalDatabaseProtocol)
        async
    {
        let getContacts = ContactUseCases.GetContacts(
            contactDataSource: contactDataSource,
            localDatabase: localDatabase
        )

        do {
            contacts = try await getContacts.execute()
            errorMessage = nil
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    // MARK: - Block / Unblock

    func blockContact(userId: String, contactDataSource: ContactDataSource) async {
        let useCase = ContactUseCases.BlockContact(contactDataSource: contactDataSource)

        do {
            try await useCase.execute(userId: userId)
            blockedUserIDs.insert(userId)
            SanchrLogger.sync.info("Blocked contact \(userId.prefix(8))...")
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func unblockContact(userId: String, contactDataSource: ContactDataSource) async {
        let useCase = ContactUseCases.UnblockContact(contactDataSource: contactDataSource)

        do {
            try await useCase.execute(userId: userId)
            blockedUserIDs.remove(userId)
            SanchrLogger.sync.info("Unblocked contact \(userId.prefix(8))...")
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    // MARK: - Load Blocked List

    func loadBlockedList(contactDataSource: ContactDataSource) async {
        let useCase = ContactUseCases.GetBlockedList(contactDataSource: contactDataSource)

        do {
            let ids = try await useCase.execute()
            blockedUserIDs = Set(ids)
        } catch {
            SanchrLogger.sync.error("Failed to load blocked list: \(error.localizedDescription)")
        }
    }
}
