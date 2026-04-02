import Foundation

/// View model for the contacts list screen.
/// Manages contacts grouped alphabetically with search, filter, block/unblock, and pull-to-refresh.
@Observable
final class ContactsViewModel {

    // MARK: - State

    var contacts: [User] = []
    var blockedUserIDs: Set<String> = []
    var isLoading: Bool = false
    var errorMessage: String?
    var hasCompletedSync: Bool = false
    var searchText: String = ""

    // MARK: - Computed

    /// Contacts filtered by search text, excluding blocked users.
    var filteredContacts: [User] {
        let base = contacts.filter { !blockedUserIDs.contains($0.id) }
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// Contacts grouped by first letter for alphabetical section headers.
    var groupedContacts: [(letter: String, contacts: [User])] {
        let sorted = filteredContacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let grouped = Dictionary(grouping: sorted) { user -> String in
            let first = user.displayName.prefix(1).uppercased()
            return first.rangeOfCharacter(from: .letters) != nil ? first : "#"
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (letter: $0.key, contacts: $0.value) }
    }

    /// Number of online contacts.
    var onlineCount: Int {
        contacts.filter { $0.status == .online }.count
    }

    // MARK: - Load Contacts

    func loadContacts(contactDataSource: ContactDataSource, localDatabase: LocalDatabaseProtocol) async {
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
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Refresh

    func refreshContacts(contactDataSource: ContactDataSource, localDatabase: LocalDatabaseProtocol) async {
        let getContacts = ContactUseCases.GetContacts(
            contactDataSource: contactDataSource,
            localDatabase: localDatabase
        )

        do {
            contacts = try await getContacts.execute()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
    }

    func unblockContact(userId: String, contactDataSource: ContactDataSource) async {
        let useCase = ContactUseCases.UnblockContact(contactDataSource: contactDataSource)

        do {
            try await useCase.execute(userId: userId)
            blockedUserIDs.remove(userId)
            SanchrLogger.sync.info("Unblocked contact \(userId.prefix(8))...")
        } catch {
            errorMessage = error.localizedDescription
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
