import SwiftUI
import QuickLook
import UIKit

/// `QLPreviewController` wrapper. QuickLook natively handles PDF,
/// Office documents (doc/docx/xls/xlsx/ppt/pptx), Pages/Numbers/
/// Keynote, images, plain text, RTF, CSV, markdown, audio, video, and
/// ZIP archives — plus a built-in share button for Save to Files,
/// Mail, Print, Copy, Open In…
///
/// If QuickLook can't preview the file (rare — proprietary formats,
/// corrupted files), we fall through to `UIDocumentInteractionController`
/// options menu so the user still gets "Open In…" at minimum.
struct DocumentPreviewView: UIViewControllerRepresentable {
    let fileURL: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if QLPreviewController.canPreview(fileURL as NSURL) {
            let ql = QLPreviewController()
            ql.dataSource = context.coordinator
            ql.delegate = context.coordinator
            ql.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: context.coordinator,
                action: #selector(Coordinator.doneTapped)
            )
            let nav = UINavigationController(rootViewController: ql)
            return nav
        } else {
            // Fallback: UIDocumentInteractionController options menu.
            let host = UIViewController()
            host.view.backgroundColor = .systemBackground
            DispatchQueue.main.async {
                let interaction = UIDocumentInteractionController(url: fileURL)
                context.coordinator.interaction = interaction
                interaction.delegate = context.coordinator
                interaction.presentOptionsMenu(
                    from: host.view.bounds,
                    in: host.view,
                    animated: true
                )
            }
            return host
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject,
                              @preconcurrency QLPreviewControllerDataSource,
                              @preconcurrency QLPreviewControllerDelegate,
                              @preconcurrency UIDocumentInteractionControllerDelegate {
        let fileURL: URL
        let onDismiss: () -> Void
        var interaction: UIDocumentInteractionController?

        init(fileURL: URL, onDismiss: @escaping () -> Void) {
            self.fileURL = fileURL
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            fileURL as NSURL
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onDismiss()
        }

        @objc func doneTapped() {
            onDismiss()
        }

        func documentInteractionControllerViewControllerForPreview(
            _ controller: UIDocumentInteractionController
        ) -> UIViewController {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first ?? UIViewController()
        }

        func documentInteractionControllerDidDismissOptionsMenu(
            _ controller: UIDocumentInteractionController
        ) {
            onDismiss()
        }
    }
}
