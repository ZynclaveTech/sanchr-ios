import SwiftUI
import UIKit
import SanchrShared

/// Bottom sheet shown when tapping a contact bubble. Which rows are
/// visible depends on the `PendingContact` state — "Message on Sanchr"
/// vs "Invite", "Save to Contacts" vs "View in Contacts", etc.
struct ContactActionSheet: View {
    let pending: ContactActionCoordinator.PendingContact
    let onMessageOnSanchr: (String) -> Void       // userId
    let onInvite: () -> Void
    let onOpenNewContact: (String, String) -> Void // name, phone
    let onOpenExistingContact: () -> Void
    let onDismiss: () -> Void

    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }

                Section {
                    if let userId = pending.resolvedSanchrUserId, !pending.isSelfContact {
                        row(icon: "message.fill", text: "Message on Sanchr", color: SanchrColors.primary) {
                            onMessageOnSanchr(userId)
                        }
                    } else if !pending.isSelfContact {
                        row(icon: "paperplane.fill", text: "Invite to Sanchr", color: SanchrColors.primary) {
                            onInvite()
                        }
                    }

                    if pending.alreadyInDeviceContacts {
                        row(icon: "person.crop.circle", text: "View in Contacts", color: .primary) {
                            onOpenExistingContact()
                        }
                    } else {
                        row(icon: "person.crop.circle.badge.plus", text: "Save to Contacts", color: .primary) {
                            onOpenNewContact(pending.name, pending.phoneNumber)
                        }
                    }

                    row(icon: "phone.fill", text: "Call", color: .primary) {
                        open(url: URL(string: "tel://\(pending.normalizedPhone)"))
                    }
                    row(icon: "message", text: "Send SMS", color: .primary) {
                        open(url: URL(string: "sms://\(pending.normalizedPhone)"))
                    }
                    row(icon: "doc.on.doc", text: "Copy number", color: .primary) {
                        UIPasteboard.general.string = pending.phoneNumber
                        toast = "Number copied"
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .padding(.bottom, 32)
                        .task(id: toast) {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { self.toast = nil }
                        }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(pending.name).font(.headline)
                Text(pending.phoneNumber).font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func row(
        icon: String,
        text: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundColor(color)
                Text(text).foregroundColor(color)
                Spacer()
            }
        }
    }

    private func open(url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }
}
