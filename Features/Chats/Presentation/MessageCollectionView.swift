import SwiftUI
import UIKit

/// SwiftUI bridge for `MessageCollectionViewController`.
/// Passes ViewModel sections and upload progress, handles scroll state bindings,
/// and wires reply / reaction callbacks.
struct MessageCollectionView: UIViewControllerRepresentable {

    let sections: [MessageSection]
    let uploadProgress: [String: Double]
    let uploadStatusLabel: [String: String]
    let onReply: (Message) -> Void
    let onReact: (String, String) -> Void
    let onLoadMore: () -> Void
    @Binding var isScrolledToBottom: Bool
    @Binding var newMessageCountWhileScrolled: Int
    @Binding var scrollToMessageId: String?

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> MessageCollectionViewController {
        let vc = MessageCollectionViewController()

        vc.onReplyToMessage = { message in
            onReply(message)
        }

        vc.onReactToMessage = { emoji, messageId in
            onReact(emoji, messageId)
        }

        vc.onScrolledToBottom = { atBottom in
            DispatchQueue.main.async {
                isScrolledToBottom = atBottom
            }
        }

        vc.onNewMessageCountWhileScrolled = { count in
            DispatchQueue.main.async {
                newMessageCountWhileScrolled = count
            }
        }

        vc.onLoadMore = {
            onLoadMore()
        }

        // Apply initial snapshot
        vc.applySnapshot(
            sections: sections,
            uploadProgress: uploadProgress,
            uploadStatusLabel: uploadStatusLabel
        )

        return vc
    }

    func updateUIViewController(_ vc: MessageCollectionViewController, context: Context) {
        // Re-wire callbacks in case closures captured new values
        vc.onReplyToMessage = { message in
            onReply(message)
        }

        vc.onReactToMessage = { emoji, messageId in
            onReact(emoji, messageId)
        }

        vc.onLoadMore = {
            onLoadMore()
        }

        // Apply updated snapshot
        vc.applySnapshot(
            sections: sections,
            uploadProgress: uploadProgress,
            uploadStatusLabel: uploadStatusLabel
        )

        // Handle scroll-to-message request
        if let targetId = scrollToMessageId {
            vc.scrollToMessage(id: targetId)
            DispatchQueue.main.async {
                scrollToMessageId = nil
            }
        }
    }
}
