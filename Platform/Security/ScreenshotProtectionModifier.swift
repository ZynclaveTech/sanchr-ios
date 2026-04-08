import SwiftUI
import UIKit
import SanchrShared
import os

private let screenshotLog = Logger(subsystem: "com.sanchr.app", category: "ScreenshotProtection")

/// View modifier that prevents screenshots and screen recording by
/// adding a zero-size secure `UITextField` behind the content via
/// `.background`. The field's presence in the window hierarchy flips
/// the system secure flag, which blanks the app-switcher snapshot and
/// — on most iOS versions — the screen-recording frames too. Pure
/// user-initiated screenshots of the host screen are not fully blocked
/// by this technique alone on iOS 17+; that requires reparenting
/// content INSIDE the text field's private container, which wrecks
/// SwiftUI layout when applied at arbitrary view positions.
///
/// Lots of os.Logger output so we can correlate on-device behavior
/// with actual secure-flag state. Filter with:
///   subsystem:com.sanchr.app category:ScreenshotProtection
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
        v.setActive(isActive, reason: "make")
        return v
    }

    func updateUIView(_ uiView: SecureMarkerView, context: Context) {
        uiView.setActive(isActive, reason: "update")
    }
}

/// A zero-size host view that carries a secure `UITextField` as its
/// only subview. The field is inert (no interaction, no editing) but
/// joins the window hierarchy and is toggled secure on demand.
final class SecureMarkerView: UIView {
    private let secureField = UITextField()
    private var pendingActive: Bool = false

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
        screenshotLog.log("SecureMarkerView.init")
    }

    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool, reason: String) {
        pendingActive = active
        secureField.isSecureTextEntry = active
        let inWindow = secureField.window != nil
        let windowSecureCount = countSecureFields(in: window)
        screenshotLog.log("setActive[\(reason)] active=\(active) fieldSecure=\(self.secureField.isSecureTextEntry) inWindow=\(inWindow) windowSecureFieldCount=\(windowSecureCount)")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Reapply now that we're in a window — that's when the
            // secure flag actually starts affecting the window.
            secureField.isSecureTextEntry = pendingActive
        }
        let windowSecureCount = countSecureFields(in: window)
        screenshotLog.log("didMoveToWindow window=\(self.window != nil ? "yes" : "nil") pendingActive=\(self.pendingActive) windowSecureFieldCount=\(windowSecureCount)")
    }

    private func countSecureFields(in root: UIView?) -> Int {
        guard let root else { return 0 }
        var n = 0
        if let tf = root as? UITextField, tf.isSecureTextEntry { n += 1 }
        for sub in root.subviews { n += countSecureFields(in: sub) }
        return n
    }
}

extension View {
    /// Applies screenshot and screen recording protection when active.
    func screenshotProtection(isActive: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isActive: isActive))
    }
}
