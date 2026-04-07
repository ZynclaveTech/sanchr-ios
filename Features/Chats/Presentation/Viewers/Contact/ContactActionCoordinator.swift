import Foundation
import SanchrShared

/// Drives the contact-bubble action sheet presentation. Resolves a
/// tapped contact's phone number against the local Sanchr contacts
/// table and the device address book, then exposes a `PendingContact`
/// snapshot the sheet uses to gate which action rows to show.
///
/// Reconfigure-able after init because `ChatDetailView` holds it as a
/// `@StateObject` and can't access `@Environment` when the `@StateObject`
/// is first constructed.
@MainActor
final class ContactActionCoordinator: ObservableObject {
    @Published var pendingContact: PendingContact?

    struct PendingContact: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let phoneNumber: String
        let normalizedPhone: String
        let resolvedSanchrUserId: String?
        let resolvedSanchrUser: User?
        let alreadyInDeviceContacts: Bool
        let isSelfContact: Bool
    }

    private var contactRepository: ContactRepositoryProtocol
    private var deviceContactMatcher: (String) -> Bool
    private var currentUserId: () -> String?
    private var phoneNormalizer: (String) -> String

    init(
        contactRepository: ContactRepositoryProtocol,
        deviceContactMatcher: @escaping (String) -> Bool,
        currentUserId: @escaping () -> String?,
        phoneNormalizer: @escaping (String) -> String
    ) {
        self.contactRepository = contactRepository
        self.deviceContactMatcher = deviceContactMatcher
        self.currentUserId = currentUserId
        self.phoneNormalizer = phoneNormalizer
    }

    /// Swap the dependencies after construction. Used by `ChatDetailView`
    /// which constructs the coordinator with bootstrap no-ops and then
    /// reconfigures with real dependencies inside `.task` once `container`
    /// is available.
    func reconfigure(
        contactRepository: ContactRepositoryProtocol,
        deviceContactMatcher: @escaping (String) -> Bool,
        currentUserId: @escaping () -> String?,
        phoneNormalizer: @escaping (String) -> String
    ) {
        self.contactRepository = contactRepository
        self.deviceContactMatcher = deviceContactMatcher
        self.currentUserId = currentUserId
        self.phoneNormalizer = phoneNormalizer
    }

    func present(name: String, phoneNumber: String) async {
        let normalized = phoneNormalizer(phoneNumber)
        let users = (try? await contactRepository.fetchContacts()) ?? []
        let match = users.first { user in
            phoneNormalizer(user.phoneNumber) == normalized
        }
        let meId = currentUserId()
        let isSelf = (match?.id == meId) && meId != nil
        pendingContact = PendingContact(
            name: name,
            phoneNumber: phoneNumber,
            normalizedPhone: normalized,
            resolvedSanchrUserId: isSelf ? nil : match?.id,
            resolvedSanchrUser: isSelf ? nil : match,
            alreadyInDeviceContacts: deviceContactMatcher(normalized),
            isSelfContact: isSelf
        )
    }

    func dismiss() {
        pendingContact = nil
    }
}
