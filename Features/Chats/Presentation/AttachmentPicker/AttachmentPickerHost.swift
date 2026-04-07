import SwiftUI
import UIKit
import SanchrShared

/// SwiftUI host wrapping the UIKit `AttachmentPickerView`.
///
/// Owns the `AttachmentPickerViewModel` (and its `PhotosLibrarySource`) for the
/// lifetime of the inline tray, forwards user-driven callbacks back to the
/// SwiftUI layer, and bridges the view model's `onIntent` closure to a
/// SwiftUI-friendly `onIntent` parameter.
@MainActor
struct AttachmentPickerHost: UIViewRepresentable {

    var onIntent: (AttachmentIntent) -> Void
    var onRequestAction: (AttachmentPillItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onIntent: onIntent, onRequestAction: onRequestAction)
    }

    func makeUIView(context: Context) -> AttachmentPickerView {
        let coordinator = context.coordinator
        let photosSource = PhotosLibrarySource()
        let viewModel = AttachmentPickerViewModel(photos: photosSource)
        viewModel.onIntent = { [weak coordinator] intent in
            coordinator?.onIntent(intent)
        }
        coordinator.viewModel = viewModel
        coordinator.photosSource = photosSource

        let view = AttachmentPickerView(viewModel: viewModel, photosSource: photosSource)
        view.onRequestAction = { [weak coordinator] item in
            coordinator?.onRequestAction(item)
        }
        coordinator.view = view
        view.didShow()
        return view
    }

    func updateUIView(_ uiView: AttachmentPickerView, context: Context) {
        context.coordinator.onIntent = onIntent
        context.coordinator.onRequestAction = onRequestAction
    }

    static func dismantleUIView(_ uiView: AttachmentPickerView, coordinator: Coordinator) {
        uiView.didHide()
    }

    @MainActor
    final class Coordinator {
        var onIntent: (AttachmentIntent) -> Void
        var onRequestAction: (AttachmentPillItem) -> Void

        weak var view: AttachmentPickerView?
        var viewModel: AttachmentPickerViewModel?
        var photosSource: PhotosLibrarySource?

        init(
            onIntent: @escaping (AttachmentIntent) -> Void,
            onRequestAction: @escaping (AttachmentPillItem) -> Void
        ) {
            self.onIntent = onIntent
            self.onRequestAction = onRequestAction
        }
    }
}
