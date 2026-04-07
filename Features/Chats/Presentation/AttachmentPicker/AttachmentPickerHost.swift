import SwiftUI
import UIKit

/// SwiftUI host wrapping the UIKit `AttachmentPickerView`.
///
/// Owns the `AttachmentPickerViewModel` (and its `PhotosLibrarySource`) for the
/// lifetime of the SwiftUI sheet, forwards user-driven callbacks back to the
/// SwiftUI layer, and bridges the view model's `onIntent` closure to a
/// SwiftUI-friendly `onIntent` parameter.
@MainActor
struct AttachmentPickerHost: UIViewRepresentable {

    var onIntent: (AttachmentIntent) -> Void
    var onRequestAllPhotos: () -> Void
    var onRequestAction: (ActionGridItem) -> Void
    var onRequestCameraCapture: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onIntent: onIntent,
            onRequestAllPhotos: onRequestAllPhotos,
            onRequestAction: onRequestAction,
            onRequestCameraCapture: onRequestCameraCapture
        )
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
        view.onRequestAllPhotos = { [weak coordinator] in
            coordinator?.onRequestAllPhotos()
        }
        view.onRequestAction = { [weak coordinator] item in
            coordinator?.onRequestAction(item)
        }
        view.onRequestCameraCapture = { [weak coordinator] in
            coordinator?.onRequestCameraCapture()
        }
        coordinator.view = view
        view.didShow()
        return view
    }

    func updateUIView(_ uiView: AttachmentPickerView, context: Context) {
        // Refresh callbacks so latest SwiftUI closures are used after re-renders.
        context.coordinator.onIntent = onIntent
        context.coordinator.onRequestAllPhotos = onRequestAllPhotos
        context.coordinator.onRequestAction = onRequestAction
        context.coordinator.onRequestCameraCapture = onRequestCameraCapture
    }

    static func dismantleUIView(_ uiView: AttachmentPickerView, coordinator: Coordinator) {
        uiView.didHide()
    }

    @MainActor
    final class Coordinator {
        var onIntent: (AttachmentIntent) -> Void
        var onRequestAllPhotos: () -> Void
        var onRequestAction: (ActionGridItem) -> Void
        var onRequestCameraCapture: () -> Void

        weak var view: AttachmentPickerView?
        var viewModel: AttachmentPickerViewModel?
        var photosSource: PhotosLibrarySource?

        init(
            onIntent: @escaping (AttachmentIntent) -> Void,
            onRequestAllPhotos: @escaping () -> Void,
            onRequestAction: @escaping (ActionGridItem) -> Void,
            onRequestCameraCapture: @escaping () -> Void
        ) {
            self.onIntent = onIntent
            self.onRequestAllPhotos = onRequestAllPhotos
            self.onRequestAction = onRequestAction
            self.onRequestCameraCapture = onRequestCameraCapture
        }
    }
}
