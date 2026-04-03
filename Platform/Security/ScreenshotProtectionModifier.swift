import SwiftUI
import UIKit

/// View modifier that prevents screenshots and screen recording
/// by embedding a hidden secure UITextField in the view hierarchy.
/// When `isActive` is true, the system treats the window as secure,
/// blanking it in the app switcher and blocking screen captures.
struct ScreenshotProtectionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .background(
                ScreenshotProtectionRepresentable(isActive: isActive)
                    .allowsHitTesting(false)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            )
    }
}

private struct ScreenshotProtectionRepresentable: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> ScreenshotProtectionView {
        ScreenshotProtectionView()
    }

    func updateUIView(_ uiView: ScreenshotProtectionView, context: Context) {
        uiView.setProtection(isActive)
    }
}

/// UIView that uses the secure text field trick to prevent screen capture.
/// The approach: a `UITextField` with `isSecureTextEntry = true` causes
/// iOS to mark the containing window as secure. We embed the text field's
/// internal subview into our view so the protection propagates to the entire window.
final class ScreenshotProtectionView: UIView {
    private let secureField = UITextField()
    private var secureContainer: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSecureField()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSecureField()
    }

    private func setupSecureField() {
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false

        // The secure text field's internal container view carries the security flag.
        // We grab it and add it to our view hierarchy so the entire window becomes secure.
        if let container = secureField.subviews.first {
            secureContainer = container
            container.translatesAutoresizingMaskIntoConstraints = false
            addSubview(container)

            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }

    func setProtection(_ active: Bool) {
        secureContainer?.isHidden = !active
    }
}

extension View {
    /// Applies screenshot and screen recording protection when active.
    func screenshotProtection(isActive: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isActive: isActive))
    }
}
