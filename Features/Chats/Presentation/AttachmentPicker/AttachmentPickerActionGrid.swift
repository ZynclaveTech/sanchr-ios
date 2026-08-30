import UIKit
import SanchrShared

enum AttachmentPillItem: String, CaseIterable {
    case camera, photos, video, gif, file, contact, location
}

@MainActor
protocol AttachmentPickerActionPillsDelegate: AnyObject {
    func actionPills(_ pills: AttachmentPickerActionPills, didTap item: AttachmentPillItem)
}

@MainActor
final class AttachmentPickerActionPills: UIView {

    weak var delegate: AttachmentPickerActionPillsDelegate?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        stack.axis = .horizontal
        stack.spacing = 18
        stack.alignment = .center
        stack.distribution = .equalSpacing
        scrollView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -18),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -16)
        ])

        for item in AttachmentPillItem.allCases {
            let pill = AttachmentPillButton(item: item)
            pill.addTarget(self, action: #selector(onTap(_:)), for: .touchUpInside)
            stack.addArrangedSubview(pill)
        }
    }

    @objc private func onTap(_ sender: AttachmentPillButton) {
        delegate?.actionPills(self, didTap: sender.item)
    }
}

@MainActor
final class AttachmentPillButton: UIControl {
    let item: AttachmentPillItem
    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(item: AttachmentPillItem) {
        self.item = item
        super.init(frame: .zero)

        iconContainer.backgroundColor = UIColor.secondarySystemBackground
        iconContainer.layer.cornerRadius = 28
        iconContainer.isUserInteractionEnabled = false
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        let cfg = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        iconView.image = UIImage(systemName: Self.symbolName(for: item), withConfiguration: cfg)
        iconView.tintColor = .label
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        titleLabel.text = Self.title(for: item)
        // Was a fixed 12pt, so the labels stayed put at every Dynamic Type
        // size including the accessibility ones.
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [iconContainer, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 56),
            iconContainer.heightAnchor.constraint(equalToConstant: 56),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor)
        ])

        isAccessibilityElement = true
        accessibilityLabel = Self.title(for: item)
        accessibilityTraits = .button
        accessibilityIdentifier = "attachmentPicker.actionPill.\(item.rawValue)"
    }
    required init?(coder: NSCoder) { fatalError() }

    static func symbolName(for item: AttachmentPillItem) -> String {
        switch item {
        case .camera: return "camera.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .video: return "video.fill"
        case .gif: return "sparkles"
        case .file: return "doc.fill"
        case .contact: return "person.crop.circle.fill"
        case .location: return "location.fill"
        }
    }
    static func title(for item: AttachmentPillItem) -> String {
        switch item {
        case .camera: return "Camera"
        case .photos: return "Photos"
        case .video: return "Video"
        case .gif: return "GIF"
        case .file: return "File"
        case .contact: return "Contact"
        case .location: return "Location"
        }
    }
}
