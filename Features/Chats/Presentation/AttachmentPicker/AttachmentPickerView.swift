import Photos
import UIKit
import Combine
import SanchrShared

@MainActor
final class AttachmentPickerView: UIView {

    private let viewModel: AttachmentPickerViewModel
    private let photosSource: PhotosLibrarySource
    private let recentsStrip: AttachmentPickerRecentsStrip
    private let actionPills = AttachmentPickerActionPills()
    /// Send / cancel for a multiple selection.
    ///
    /// Long-pressing a photo started a selection and numbered every tap after
    /// it, and there was nothing to press to send them —
    /// `didConfirmRecentSelection` and `didCancelMultiSelect` were called from
    /// nowhere at all. Closing the tray silently threw the selection away, and
    /// that was the only way out.
    private let selectionBar = AttachmentSelectionBar()
    /// Says what went wrong. The view model wrote four different messages into
    /// `transientError` and nothing ever read it, so a photo that failed to
    /// load, or a selection over the limit, was indistinguishable from a tap
    /// that did nothing.
    private let messageLabel = UILabel()
    /// Shown in place of the strip when there is nothing in it.
    private let emptyView = AttachmentPickerEmptyView()
    /// Offered when the library is shared only in part.
    ///
    /// iOS lets someone grant access to a chosen handful of photos and expects
    /// the app to provide a way to revise that choice. There was none, so a
    /// limited library was a strip of whatever had been picked once, with no
    /// route to add to it.
    private let manageAccessButton = UIButton(type: .system)

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
        selectionBar.delegate = self
        selectionBar.isHidden = true

        emptyView.isHidden = true
        emptyView.onOpenSettings = {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }

        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 2
        messageLabel.isHidden = true

        manageAccessButton.setTitle("Select More Photos…", for: .normal)
        manageAccessButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        manageAccessButton.titleLabel?.adjustsFontForContentSizeCategory = true
        manageAccessButton.isHidden = true
        manageAccessButton.addAction(
            UIAction { [weak self] _ in self?.presentLimitedLibraryPicker() },
            for: .primaryActionTriggered
        )

        let stack = UIStackView(arrangedSubviews: [
            selectionBar, messageLabel, recentsStrip, manageAccessButton, actionPills
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(4, after: selectionBar)
        addSubview(stack)
        addSubview(emptyView)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Stack sizes itself to its content (strip 124 + spacing 8 +
        // pills 96 = 228pt). Anchored to top so the bottom floats above
        // the safe area without over-constraining the container height.
        // The SwiftUI parent sets the picker container frame; see
        // ChatDetailView's `.frame(height:)` on AttachmentPickerHost.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            recentsStrip.heightAnchor.constraint(equalToConstant: 124),
            actionPills.heightAnchor.constraint(equalToConstant: 96),

            emptyView.topAnchor.constraint(equalTo: recentsStrip.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: recentsStrip.bottomAnchor),
            emptyView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    private func bind() {
        viewModel.$recents
            .combineLatest(viewModel.$selectedRecentIDs, viewModel.$isMultiSelecting)
            .receive(on: RunLoop.main)
            .sink { [weak self] recents, selected, multi in
                guard let self else { return }
                self.recentsStrip.update(recents: recents, selected: selected, multiSelecting: multi)
                self.selectionBar.update(count: selected.count, limit: AttachmentPickerViewModel.selectionLimit)
                self.selectionBar.isHidden = !multi
                self.refreshEmptyState()
            }
            .store(in: &cancellables)

        viewModel.$isLoadingRecents
            .combineLatest(viewModel.$photoPermission)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshEmptyState() }
            .store(in: &cancellables)

        viewModel.$transientError
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.show(message: message) }
            .store(in: &cancellables)
    }

    private func refreshEmptyState() {
        let reason = viewModel.emptyReason
        emptyView.isHidden = reason == nil
        // Faded, not hidden. The strip is an arranged subview, and a stack
        // view collapses those — which took its height with it, and the empty
        // message is pinned to the strip's bounds, so the explanation had
        // nowhere to be drawn and disappeared along with the photos it was
        // there to account for.
        recentsStrip.alpha = reason == nil ? 1 : 0
        recentsStrip.isUserInteractionEnabled = reason == nil
        if let reason { emptyView.configure(reason) }
        manageAccessButton.isHidden = viewModel.photoPermission != .limited
    }

    /// The system sheet for revising a limited selection. Photos changed
    /// underneath us afterwards, so the strip is re-read.
    private func presentLimitedLibraryPicker() {
        guard let controller = nearestViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        Task { @MainActor in
            // The sheet is modal; re-read once it has been dismissed.
            while controller.presentedViewController != nil {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await viewModel.reloadRecents()
        }
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }

    private var messageDismissal: Task<Void, Never>?

    private func show(message: String?) {
        messageDismissal?.cancel()
        guard let message, !message.isEmpty else {
            messageLabel.isHidden = true
            return
        }
        messageLabel.text = message
        messageLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
        messageDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.messageLabel.isHidden = true
            self?.viewModel.transientError = nil
        }
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
extension AttachmentPickerView: AttachmentSelectionBarDelegate {
    func selectionBarDidConfirm(_ bar: AttachmentSelectionBar) {
        Task { @MainActor in await viewModel.didConfirmRecentSelection() }
    }

    func selectionBarDidCancel(_ bar: AttachmentSelectionBar) {
        viewModel.didCancelMultiSelect()
    }
}

@MainActor
extension AttachmentPickerView: AttachmentPickerActionPillsDelegate {
    func actionPills(_ pills: AttachmentPickerActionPills, didTap item: AttachmentPillItem) {
        onRequestAction?(item)
    }
}
