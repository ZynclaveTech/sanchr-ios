import UIKit
import Combine

@MainActor
final class AttachmentPickerView: UIView {

    private let viewModel: AttachmentPickerViewModel
    private let photosSource: PhotosLibrarySource
    private let header = UIView()
    private let e2eeChip = UILabel()
    private let recentsStrip: AttachmentPickerRecentsStrip
    private let allPhotosLink = UIButton(type: .system)
    private let actionGrid = AttachmentPickerActionGrid()

    private var cancellables = Set<AnyCancellable>()

    var onRequestAllPhotos: (() -> Void)?
    var onRequestAction: ((ActionGridItem) -> Void)?
    var onRequestCameraCapture: (() -> Void)?

    init(viewModel: AttachmentPickerViewModel, photosSource: PhotosLibrarySource) {
        self.viewModel = viewModel
        self.photosSource = photosSource
        self.recentsStrip = AttachmentPickerRecentsStrip(photosSource: photosSource)
        super.init(frame: .zero)
        setupUI()
        bind()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        backgroundColor = UIColor.systemBackground
        layer.cornerRadius = 16
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        let chipFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let shieldAttachment = NSTextAttachment()
        let shieldCfg = UIImage.SymbolConfiguration(font: chipFont)
        shieldAttachment.image = UIImage(systemName: "lock.shield.fill", withConfiguration: shieldCfg)?
            .withTintColor(.systemPurple, renderingMode: .alwaysOriginal)
        let chipString = NSMutableAttributedString(attachment: shieldAttachment)
        chipString.append(NSAttributedString(
            string: " E2EE",
            attributes: [.font: chipFont, .foregroundColor: UIColor.systemPurple]
        ))
        e2eeChip.attributedText = chipString
        e2eeChip.font = chipFont
        e2eeChip.textColor = .systemPurple
        e2eeChip.isAccessibilityElement = true
        e2eeChip.accessibilityLabel = "End-to-end encrypted"
        e2eeChip.accessibilityHint = "All attachments are encrypted on your device before sending"
        e2eeChip.accessibilityIdentifier = "attachmentPicker.header.e2eeChip"

        let title = UILabel()
        title.text = "Attach"
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        allPhotosLink.setTitle("All Photos →", for: .normal)
        allPhotosLink.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        allPhotosLink.addTarget(self, action: #selector(onAllPhotos), for: .touchUpInside)
        allPhotosLink.isAccessibilityElement = true
        allPhotosLink.accessibilityLabel = "All Photos"
        allPhotosLink.accessibilityIdentifier = "attachmentPicker.header.allPhotos"

        let headerStack = UIStackView(arrangedSubviews: [title, e2eeChip, UIView(), allPhotosLink])
        headerStack.axis = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .center
        header.addSubview(headerStack)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            headerStack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6)
        ])

        recentsStrip.delegate = self
        actionGrid.delegate = self

        let stack = UIStackView(arrangedSubviews: [header, recentsStrip, actionGrid])
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            recentsStrip.heightAnchor.constraint(equalToConstant: 94)
        ])
    }

    private func bind() {
        viewModel.$recents
            .combineLatest(viewModel.$selectedRecentIDs, viewModel.$isMultiSelecting)
            .receive(on: RunLoop.main)
            .sink { [weak self] recents, selected, multi in
                self?.recentsStrip.update(recents: recents, selected: selected, multiSelecting: multi)
            }
            .store(in: &cancellables)
    }

    @objc private func onAllPhotos() { onRequestAllPhotos?() }

    func didShow() { viewModel.didAppear() }

    func didHide() {
        viewModel.didDisappear()
        CameraTileCell.stopSession()
    }
}

@MainActor
extension AttachmentPickerView: AttachmentPickerRecentsStripDelegate {
    func recentsStrip(_ s: AttachmentPickerRecentsStrip, didTapPhotoAt id: String) {
        Task { @MainActor in await viewModel.didTapRecentPhoto(id: id) }
    }
    func recentsStrip(_ s: AttachmentPickerRecentsStrip, didLongPressPhotoAt id: String) {
        viewModel.didLongPressRecent(id: id)
    }
    func recentsStripDidTapCameraTile(_ s: AttachmentPickerRecentsStrip) {
        onRequestCameraCapture?()
    }
}

@MainActor
extension AttachmentPickerView: AttachmentPickerActionGridDelegate {
    func actionGrid(_ g: AttachmentPickerActionGrid, didTap item: ActionGridItem) {
        onRequestAction?(item)
    }
}
