import SwiftUI
import UIKit

/// Hosts the context menu in a window of its own, above everything the chat
/// screen draws.
///
/// It began as a SwiftUI `.overlay` on the transcript, which is one child of
/// the chat screen's VStack — so it could only ever cover the transcript. The
/// header, the encryption banner and the composer stayed sharp and on top, and
/// the action list ran underneath the composer instead of over it.
///
/// A window also settles the coordinate question. `sourceFrame` is measured in
/// window coordinates, and those only agree with the overlay's own space if the
/// overlay *is* the window. As a transcript overlay it was off by the height of
/// everything above the transcript.
///
/// Signal reaches for the same tool for the same reason: its context menu is
/// presented over the whole screen rather than inside the view it came from.
@MainActor
final class MessageContextMenuWindow {

    private var window: UIWindow?

    /// The chat's own window, hidden from VoiceOver while the menu is up and
    /// restored when it goes.
    private weak var obscuredHost: UIWindow?

    /// The window the chat is drawn in — the space `sourceFrame` is measured in.
    static var host: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }
    }

    func present(_ content: some View, colorScheme: ColorScheme?) {
        guard let host = Self.host, let scene = host.windowScene else { return }
        dismiss()

        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        // Signal marks its context menu's root view modal for the same reason:
        // everything behind it is blurred and untouchable, so VoiceOver has no
        // business reaching it.
        controller.view.accessibilityViewIsModal = true

        let window = UIWindow(windowScene: scene)
        window.frame = host.frame
        // Above the chat, below system alerts.
        window.windowLevel = host.windowLevel + 1
        window.backgroundColor = .clear
        // The chat screen can force light or dark per conversation, and a new
        // window would otherwise follow the system instead.
        window.overrideUserInterfaceStyle =
            switch colorScheme {
            case .light: .light
            case .dark: .dark
            default: .unspecified
            }
        window.rootViewController = controller
        // Deliberately not `makeKey`: the window needs touches, not first
        // responder status, and taking key would disturb the composer's focus.
        window.isHidden = false

        // `accessibilityViewIsModal` contains VoiceOver among *sibling views*.
        // The chat is a sibling window, so it stays reachable on its own —
        // swiping past the last action walked straight into a transcript that
        // was blurred out and could not be touched. Hiding the host window is
        // what actually confines the cursor.
        host.accessibilityElementsHidden = true
        obscuredHost = host

        self.window = window

        // Move the cursor into the menu rather than leaving it wherever the
        // long press left it.
        UIAccessibility.post(notification: .screenChanged, argument: controller.view)
    }

    func dismiss() {
        let wasPresented = window != nil

        obscuredHost?.accessibilityElementsHidden = false
        obscuredHost = nil

        window?.isHidden = true
        window?.rootViewController = nil
        window = nil

        // Hand focus back to the conversation. Without this the cursor is left
        // pointing at a window that no longer exists, and VoiceOver goes quiet.
        if wasPresented {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    deinit {
        // `window` is main-actor isolated; hop rather than touch it here.
        MainActor.assumeIsolated { dismiss() }
    }
}
