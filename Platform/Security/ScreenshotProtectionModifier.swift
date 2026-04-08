import SwiftUI
import UIKit
import SanchrShared

/// Screenshot protection on iOS is limited to:
///
/// 1. Blanking the app-switcher snapshot and screen-recording frames
///    by having a secure `UITextField` in the window hierarchy.
/// 2. Detecting user-initiated screenshots via
///    `UIApplication.userDidTakeScreenshotNotification` and surfacing
///    a system event to the peer (handled elsewhere).
///
/// Previous attempts to block user screenshots by reparenting content
/// into `UITextField.subviews.first` (the private canvas view) stopped
/// working on iOS 26 because that slot now contains a
/// `_UITouchPassthroughView` rather than a content-bearing canvas.
/// Reparenting into it broke layout and dropped touches, so we no
/// longer attempt it.
struct ScreenshotProtectionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.background(
            SecureFieldBridge(isActive: isActive)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct SecureFieldBridge: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> SecureMarkerView {
        let v = SecureMarkerView()
        v.setActive(isActive)
        return v
    }

    func updateUIView(_ uiView: SecureMarkerView, context: Context) {
        uiView.setActive(isActive)
    }
}

/// Zero-size host view carrying an inert secure `UITextField`. Its
/// presence in the window hierarchy flips the system secure flag for
/// app-switcher snapshots and screen recording.
final class SecureMarkerView: UIView {
    private let secureField = UITextField()
    private var pendingActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true

        secureField.isSecureTextEntry = false
        secureField.isUserInteractionEnabled = false
        secureField.backgroundColor = .clear
        secureField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.widthAnchor.constraint(equalToConstant: 0),
            secureField.heightAnchor.constraint(equalToConstant: 0),
            secureField.topAnchor.constraint(equalTo: topAnchor),
            secureField.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool) {
        pendingActive = active
        secureField.isSecureTextEntry = active
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            secureField.isSecureTextEntry = pendingActive
        }
    }
}

extension View {
    /// Applies screen-capture dimming when active. Blanks the app
    /// switcher snapshot and screen-recording frames; user-initiated
    /// screenshots are not blocked but are detected separately and
    /// surfaced to the peer as a system event.
    func screenshotProtection(isActive: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isActive: isActive))
    }
}
