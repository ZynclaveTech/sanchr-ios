import SwiftUI
import UIKit
import SanchrShared

/// View modifier that prevents screenshots and screen recording by
/// placing a secure `UITextField` as a sibling of the hosted content.
/// When `isActive` is true and the field is part of the window's view
/// hierarchy with `isSecureTextEntry = true`, iOS marks the window as
/// secure — blanking it in the app switcher and blocking screenshots
/// — without us having to reparent anything into the field's private
/// container view.
///
/// Why not reparent into `secureField.subviews.first`?
/// The old trick nested content inside the text field's private secure
/// container. On iOS 17 that view is opaque black and mis-propagates
/// `isHidden` / `isUserInteractionEnabled` to children, so either the
/// whole screen renders black or every touch is dropped. Having the
/// secure field present in the same window is sufficient to flip the
/// system secure flag on modern iOS, so we keep things simple.
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
        SecureMarkerView()
    }

    func updateUIView(_ uiView: SecureMarkerView, context: Context) {
        uiView.setActive(isActive)
    }
}

/// A zero-size marker view that carries a secure `UITextField` as a
/// subview. The field is not user-interactive and not visible; its
/// sole purpose is to sit in the window hierarchy and flip the system
/// secure flag when `isSecureTextEntry` is true.
final class SecureMarkerView: UIView {
    private let secureField = UITextField()

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
        secureField.isSecureTextEntry = active
    }
}

extension View {
    /// Applies screenshot and screen recording protection when active.
    func screenshotProtection(isActive: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isActive: isActive))
    }
}
