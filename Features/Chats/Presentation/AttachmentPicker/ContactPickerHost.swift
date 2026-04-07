// ContactPickerHost.swift
// SwiftUI bridge around CNContactPickerViewController. Strips the picked
// CNContact through ContactSource.strip() before emitting — never exposes
// the raw CNContact (no avatars, no postal, no birthday, no notes).
import SwiftUI
import Contacts
import ContactsUI

struct ContactPickerHost: UIViewControllerRepresentable {
    var onPick: (StrippedContact) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Limit fields fetched: only name, phones, emails. Anything else is
        // ignored by ContactSource.strip() but we constrain at the source too.
        picker.displayedPropertyKeys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var onPick: (StrippedContact) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping (StrippedContact) -> Void,
             onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard let stripped = ContactSource.strip(contact) else {
                onCancel()
                return
            }
            onPick(stripped)
        }
    }
}
