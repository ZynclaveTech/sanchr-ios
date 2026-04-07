import SwiftUI
import UIKit

enum TranscriptScrollCommand: Equatable {
    case initialBottom(sequence: UInt64)
    case manualBottom(sequence: UInt64)
    case message(id: String, sequence: UInt64)
}

struct TranscriptRenderInput {
    let sections: [MessageSection]
    let uploadProgress: [String: Double]
    let uploadStatusLabel: [String: String]
    let version: UInt64
    let scrollCommand: TranscriptScrollCommand?
}

/// SwiftUI bridge for `MessageCollectionViewController`.
/// Passes ViewModel sections and upload progress, handles scroll state bindings,
/// and wires reply / reaction callbacks.
struct MessageCollectionView: UIViewControllerRepresentable {

    let renderInput: TranscriptRenderInput
    let onInitialPresentation: () -> Void
    let onReply: (Message) -> Void
    let onReact: (String, String) -> Void
    let onLoadMore: () -> Void
    @Binding var isScrolledToBottom: Bool
    @Binding var newMessageCountWhileScrolled: Int

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> MessageCollectionViewController {
        let vc = MessageCollectionViewController()

        vc.onReplyToMessage = { message in
            onReply(message)
        }

        vc.onInitialContentPresented = {
            DispatchQueue.main.async {
                onInitialPresentation()
            }
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

        vc.update(renderInput: renderInput)

        return vc
    }

    func updateUIViewController(_ vc: MessageCollectionViewController, context: Context) {
        // Re-wire callbacks in case closures captured new values
        vc.onReplyToMessage = { message in
            onReply(message)
        }

        vc.onInitialContentPresented = {
            DispatchQueue.main.async {
                onInitialPresentation()
            }
        }

        vc.onReactToMessage = { emoji, messageId in
            onReact(emoji, messageId)
        }

        vc.onLoadMore = {
            onLoadMore()
        }

        vc.update(renderInput: renderInput)
    }
}
