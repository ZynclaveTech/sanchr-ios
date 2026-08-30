import UIKit

/// Shown where the recents strip would be when there is nothing in it.
///
/// A refused photo library and a phone with no photos on it both rendered as
/// blank space, so there was no way to tell a decision you had made from an
/// empty camera roll — and no route back from the refusal, which iOS only
/// offers through Settings.
@MainActor
final class AttachmentPickerEmptyView: UIView {

    var onOpenSettings: (() -> Void)?

    private let label = UILabel()
    private let settingsButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 3

        settingsButton.setTitle("Open Settings", for: .normal)
        settingsButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        settingsButton.titleLabel?.adjustsFontForContentSizeCategory = true
        settingsButton.addAction(
            UIAction { [weak self] _ in self?.onOpenSettings?() },
            for: .primaryActionTriggered
        )

        let stack = UIStackView(arrangedSubviews: [spinner, label, settingsButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ reason: AttachmentPickerViewModel.EmptyReason) {
        switch reason {
        case .loading:
            spinner.startAnimating()
            spinner.isHidden = false
            label.text = "Loading photos…"
            settingsButton.isHidden = true
        case .denied:
            spinner.stopAnimating()
            spinner.isHidden = true
            label.text = "Sanchr doesn't have access to your photos."
            settingsButton.isHidden = false
        case .noPhotos:
            spinner.stopAnimating()
            spinner.isHidden = true
            label.text = "No recent photos."
            settingsButton.isHidden = true
        }
        isAccessibilityElement = true
        accessibilityLabel = label.text
    }
}
