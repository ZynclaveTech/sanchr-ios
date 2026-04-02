import Foundation

/// View model for the contacts list screen.
@Observable
final class ContactsViewModel {
    var contacts: [User] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var hasCompletedSync: Bool = false

    func filteredContacts(searchText: String) -> [User] {
        guard !searchText.isEmpty else { return contacts }
        return contacts.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    func loadContacts(contactRepository: ContactRepositoryProtocol) async {
        isLoading = true
        defer { isLoading = false }

        do {
            contacts = try await contactRepository.fetchContacts()
            hasCompletedSync = !contacts.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshContacts(contactRepository: ContactRepositoryProtocol) async {
        do {
            contacts = try await contactRepository.fetchContacts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
