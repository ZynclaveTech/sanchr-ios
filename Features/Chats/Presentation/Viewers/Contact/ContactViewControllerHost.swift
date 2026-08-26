import SwiftUI
import Contacts
import ContactsUI

/// `CNContactViewController` wrapper. Supports two modes: new-contact
/// (pre-filled from a received contact bubble) and existing-contact
/// (read-only, when the phone is already in the user's address book).
struct ContactViewControllerHost: UIViewControllerRepresentable {
    enum Mode {
        case newContact(name: String, phone: String)
        case existing(CNContact)
    }

    let mode: Mode
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc: CNContactViewController
        switch mode {
        case .newContact(let name, let phone):
            let contact = CNMutableContact()
            let components = name.split(separator: " ", maxSplits: 1).map(String.init)
            contact.givenName = components.first ?? name
            contact.familyName = components.count > 1 ? components[1] : ""
            // A QR-paired peer often has no phone number; adding an empty phone
            // field would just clutter the new-contact sheet, so only prefill one
            // when we actually have it.
            if !phone.isEmpty {
                contact.phoneNumbers = [
                    CNLabeledValue(
                        label: CNLabelPhoneNumberMobile,
                        value: CNPhoneNumber(stringValue: phone)
                    )
                ]
            }
            vc = CNContactViewController(forNewContact: contact)
        case .existing(let contact):
            vc = CNContactViewController(for: contact)
        }
        vc.delegate = context.coordinator
        let nav = UINavigationController(rootViewController: vc)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }
        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            onDismiss()
        }
    }
}
