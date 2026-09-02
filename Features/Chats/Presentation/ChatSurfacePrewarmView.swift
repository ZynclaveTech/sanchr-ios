import SanchrShared
import SwiftUI

/// Pays the first-use cost of the chat screen's building blocks while the
/// splash is idle, so the first push into a chat does not.
///
/// Measured cold in a fresh process on the simulator (a device is slower):
/// an empty hosted view 38 ms, a multi-line `TextField` 94 ms, one glass
/// button 96 ms, a 50-row transcript 193 ms, the whole chat screen 700 ms —
/// and 45 ms once warm. None of that is the app's own work; it is UIKit's
/// text-input system, the glass renderer, hosting-configuration cells and
/// text shaping initialising on first use. The splash sits for over a
/// second doing nothing, which is where this belongs.
///
/// Rendered at zero opacity behind the splash, off-limits to touch and
/// VoiceOver. Content is inert placeholder data: no database, no network,
/// no side effects. It mounts with the splash's first frame on purpose: the
/// launch screen still covers the window then, and a deferred mount (via
/// `.task` or a dispatched state flip) could not be shown to run at all.
struct ChatSurfacePrewarmView: View {
    @State private var text = ""
    @State private var atBottom = false
    @State private var count = 0

    private static let messages: [Message] = (0..<3).map { i in
        Message.textMessage(
            id: "prewarm-\(i)", conversationId: "prewarm", senderId: i == 1 ? "me" : "peer",
            text: "Warming up the transcript so the first chat opens without a pause.",
            isOutgoing: i == 1
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            MessageCollectionView(
                renderInput: TranscriptRenderInput(
                    sections: ChatDetailViewModel.buildSections(from: Self.messages, calendar: .current),
                    uploads: UploadProgressStore(), uploadsVersion: 0, version: 1,
                    scrollCommand: .initialBottom(sequence: 0), firstUnreadMessageId: nil
                ),
                peerDisplayName: "", localUserId: "me", voicePlayback: VoicePlaybackController(),
                onInitialPresentation: {}, onReply: { _ in }, onReact: { _, _ in }, onDeleteMessage: { _ in },
                onForward: { _ in }, onMediaAction: { _, _ in }, onLongPressMessage: { _ in },
                onRetry: { _ in }, onLoadMore: {}, onBubbleTap: { _ in },
                isScrolledToBottom: $atBottom, newMessageCountWhileScrolled: $count
            )
            .frame(height: 200)

            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
                    .sanchrGlass(role: .floatingAction, interactive: true, prominence: .prominent,
                                 tint: SanchrColors.primary.opacity(0.18))
                TextField("Message...", text: $text, axis: .vertical)
                    .font(SanchrTypography.messageBubbleText)
                    .lineLimit(1...5)
                Text("0:06")
                    .font(SanchrTypography.font(size: .xxs, weight: .medium).monospacedDigit())
                Text("Aa")
                    .font(SanchrTypography.bodyBold)
                // The header's toolbar buttons and the chips use the other
                // two glass shapes; each shape has its own first cost.
                Image(systemName: "phone")
                    .frame(width: 36, height: 36)
                    .sanchrGlass(role: .toolbarButton, interactive: true)
                Text("chip")
                    .font(SanchrTypography.captionSmall)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .sanchrGlass(role: .chip)
            }
            .padding(12)
        }
        .frame(width: 390)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
