import UIKit

@MainActor
protocol AttachmentSelectionBarDelegate: AnyObject {
    func selectionBarDidConfirm(_ bar: AttachmentSelectionBar)
    func selectionBarDidCancel(_ bar: AttachmentSelectionBar)
}

/// Send and cancel for a multiple selection.
///
/// Selecting several photos was a complete feature with no way to finish it:
/// long-press began a selection, every tap after it added a numbered badge,
/// and the two methods that would have sent or cleared them were called from
/// nowhere. The only exit was to close the tray, which discarded the lot in
/// silence.
@MainActor
final class AttachmentSelectionBar: UIView {

    weak var delegate: AttachmentSelectionBarDelegate?

    private let countLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .label

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.selectionBarDidCancel(self)
            },
            for: .primaryActionTriggered
        )

        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        sendButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.selectionBarDidConfirm(self)
            },
            for: .primaryActionTriggered
        )

        let stack = UIStackView(arrangedSubviews: [cancelButton, countLabel, sendButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 4, leading: 16, bottom: 4, trailing: 16)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(count: Int, limit: Int) {
        countLabel.text = count == 1 ? "1 selected" : "\(count) selected"
        // At the ceiling the count is the only warning there is, so it says so
        // rather than waiting for the next tap to be refused.
        countLabel.textColor = count >= limit ? .systemOrange : .label
        sendButton.isEnabled = count > 0
        sendButton.accessibilityLabel = count == 1
            ? "Send 1 photo"
            : "Send \(count) photos"
        cancelButton.accessibilityLabel = "Cancel selection"
    }
}
