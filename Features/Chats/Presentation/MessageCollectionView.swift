import SwiftUI
import UIKit
import SanchrShared

enum TranscriptScrollCommand: Equatable {
    case initialBottom(sequence: UInt64)
    case manualBottom(sequence: UInt64)
    case message(id: String, sequence: UInt64)
}

struct TranscriptRenderInput {
    let sections: [MessageSection]
    /// Live reference to the uploads store. Cells read current progress /
    /// status through this; the controller never reads its fields directly
    /// into a snapshot — that would defeat the throttled-reconfigure path.
    let uploads: UploadProgressStore
    /// Snapshot of `uploads.version` at construction time. The controller
    /// uses this (not the live store) to decide whether to perform a
    /// reconfigure-only apply. Decoupled so we can diff without touching
    /// the store's observable fields.
    let uploadsVersion: UInt64
    let version: UInt64
    let scrollCommand: TranscriptScrollCommand?
    /// ID of the first unread message. When set, a "New Messages" divider
    /// is injected immediately above this message in the collection view.
    let firstUnreadMessageId: String?
}

/// SwiftUI bridge for `MessageCollectionViewController`.
/// Passes ViewModel sections and upload progress, handles scroll state bindings,
/// and wires reply / reaction callbacks.
struct MessageCollectionView: UIViewControllerRepresentable {

    let renderInput: TranscriptRenderInput
    let voicePlayback: VoicePlaybackController
    let onInitialPresentation: () -> Void
    let onReply: (Message) -> Void
    let onReact: (String, String) -> Void
    let onDeleteMessage: (Message) -> Void
    let onForward: (Message) -> Void
    let onRetry: (Message) -> Void
    let onLoadMore: () -> Void
    let onBubbleTap: (MessageInteraction) -> Void
    @Binding var isScrolledToBottom: Bool
    @Binding var newMessageCountWhileScrolled: Int

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> MessageCollectionViewController {
        let vc = MessageCollectionViewController()
        vc.voicePlayback = voicePlayback

        vc.onReplyToMessage = { message in
            onReply(message)
        }

        vc.onForwardMessage = { message in
            onForward(message)
        }

        vc.onRetryMessage = { message in
            onRetry(message)
        }

        vc.onInitialContentPresented = {
            DispatchQueue.main.async {
                onInitialPresentation()
            }
        }

        vc.onReactToMessage = { emoji, messageId in
            onReact(emoji, messageId)
        }

        vc.onDeleteMessage = { message in
            onDeleteMessage(message)
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

        vc.onBubbleTap = { interaction in
            onBubbleTap(interaction)
        }

        vc.firstUnreadMessageId = renderInput.firstUnreadMessageId
        vc.update(renderInput: renderInput)

        return vc
    }

    func updateUIViewController(_ vc: MessageCollectionViewController, context: Context) {
        vc.voicePlayback = voicePlayback
        // Re-wire callbacks in case closures captured new values
        vc.onReplyToMessage = { message in
            onReply(message)
        }

        vc.onForwardMessage = { message in
            onForward(message)
        }

        vc.onRetryMessage = { message in
            onRetry(message)
        }

        vc.onInitialContentPresented = {
            DispatchQueue.main.async {
                onInitialPresentation()
            }
        }

        vc.onReactToMessage = { emoji, messageId in
            onReact(emoji, messageId)
        }

        vc.onDeleteMessage = { message in
            onDeleteMessage(message)
        }

        vc.onLoadMore = {
            onLoadMore()
        }

        vc.onBubbleTap = { interaction in
            onBubbleTap(interaction)
        }

        vc.firstUnreadMessageId = renderInput.firstUnreadMessageId
        vc.update(renderInput: renderInput)
    }
}
