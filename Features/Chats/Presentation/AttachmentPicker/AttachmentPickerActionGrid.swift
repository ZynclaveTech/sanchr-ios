import UIKit

@MainActor
protocol AttachmentPickerActionGridDelegate: AnyObject {
    func actionGrid(_ grid: AttachmentPickerActionGrid, didTap item: ActionGridItem)
}

@MainActor
final class AttachmentPickerActionGrid: UIView {

    weak var delegate: AttachmentPickerActionGridDelegate?

    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 6
        stack.distribution = .fillEqually
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        let row1 = UIStackView(arrangedSubviews: [makeTile(.vault), makeTile(.file)])
        let row2 = UIStackView(arrangedSubviews: [makeTile(.contact), makeTile(.location)])
        for row in [row1, row2] {
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually
        }
        stack.addArrangedSubview(row1)
        stack.addArrangedSubview(row2)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeTile(_ item: ActionGridItem) -> UIControl {
        let btn = AttachmentGridTile(item: item)
        btn.addTarget(self, action: #selector(onTap(_:)), for: .touchUpInside)
        return btn
    }

    @objc private func onTap(_ sender: AttachmentGridTile) {
        delegate?.actionGrid(self, didTap: sender.item)
    }
}

@MainActor
final class AttachmentGridTile: UIControl {
    let item: ActionGridItem
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    init(item: ActionGridItem) {
        self.item = item
        super.init(frame: .zero)
        layer.cornerRadius = 12
        backgroundColor = UIColor.secondarySystemBackground
        if item == .vault {
            backgroundColor = UIColor.systemPurple.withAlphaComponent(0.18)
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        iconView.image = UIImage(systemName: Self.symbolName(for: item), withConfiguration: cfg)
        iconView.tintColor = (item == .vault) ? .systemPurple : .label
        iconView.contentMode = .scaleAspectFit
        titleLabel.text = Self.title(for: item)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityLabel = Self.a11yLabel(for: item)
        accessibilityTraits = .button
        accessibilityIdentifier = Self.a11yIdentifier(for: item)
    }

    static func a11yLabel(for item: ActionGridItem) -> String {
        switch item {
        case .vault: return "Vault, encrypted"
        case .file: return "Files"
        case .contact: return "Contact"
        case .location: return "Location"
        }
    }

    static func a11yIdentifier(for item: ActionGridItem) -> String {
        switch item {
        case .vault: return "attachmentPicker.actionGrid.vault"
        case .file: return "attachmentPicker.actionGrid.file"
        case .contact: return "attachmentPicker.actionGrid.contact"
        case .location: return "attachmentPicker.actionGrid.location"
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func symbolName(for item: ActionGridItem) -> String {
        switch item {
        case .vault: return "lock.shield.fill"
        case .file: return "doc.fill"
        case .contact: return "person.crop.circle.fill"
        case .location: return "mappin.and.ellipse"
        }
    }
    static func title(for item: ActionGridItem) -> String {
        switch item { case .vault: return "Vault"; case .file: return "File"; case .contact: return "Contact"; case .location: return "Location" }
    }
}
