import UIKit
import Combine

@MainActor
final class AttachmentPickerView: UIView {

    private let viewModel: AttachmentPickerViewModel
    private let photosSource: PhotosLibrarySource
    private let recentsStrip: AttachmentPickerRecentsStrip
    private let actionPills = AttachmentPickerActionPills()

    private var cancellables = Set<AnyCancellable>()

    var onRequestAction: ((AttachmentPillItem) -> Void)?

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

        recentsStrip.delegate = self
        actionPills.delegate = self

        let stack = UIStackView(arrangedSubviews: [recentsStrip, actionPills])
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            recentsStrip.heightAnchor.constraint(equalToConstant: 96),
            actionPills.heightAnchor.constraint(equalToConstant: 96)
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

    func didShow() { viewModel.didAppear() }
    func didHide() { viewModel.didDisappear() }
}

@MainActor
extension AttachmentPickerView: AttachmentPickerRecentsStripDelegate {
    func recentsStrip(_ s: AttachmentPickerRecentsStrip, didTapPhotoAt id: String) {
        Task { @MainActor in await viewModel.didTapRecentPhoto(id: id) }
    }
    func recentsStrip(_ s: AttachmentPickerRecentsStrip, didLongPressPhotoAt id: String) {
        viewModel.didLongPressRecent(id: id)
    }
}

@MainActor
extension AttachmentPickerView: AttachmentPickerActionPillsDelegate {
    func actionPills(_ pills: AttachmentPickerActionPills, didTap item: AttachmentPillItem) {
        onRequestAction?(item)
    }
}
