import SwiftUI
import SanchrShared

/// The long-press menu: a reaction bar above the message, the message itself
/// lifted out of a blurred transcript, and the actions below it.
///
/// Built rather than configured. A native `UIContextMenuInteraction` has no way
/// to put anything above its preview, which is why the reaction bar previously
/// stood *in place of* the message instead of above it. Signal hit the same wall
/// and wrote its own context menu system for the same reason.
struct MessageContextMenuOverlay: View {

    let presentation: MessageContextPresentation
    let onReact: (String) -> Void
    let onAction: (MessageContextAction) -> Void
    let onDismiss: () -> Void

    @State private var hasAppeared = false

    /// The six that cover almost every reaction, in the order Signal and
    /// WhatsApp both settled on.
    private static let quickReactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]

    private var actions: [MessageContextAction] {
        MessageContextAction.actions(
            isOutgoing: presentation.isOutgoing,
            isSaveableMedia: presentation.isSaveableMedia,
            canRetry: presentation.canRetry,
            isText: presentation.message.content.isTextForCopying
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let safeArea = CGRect(
                x: 0,
                y: proxy.safeAreaInsets.top,
                width: proxy.size.width,
                height: proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom
            )
            let messageFrame = presentation.sourceFrame
            let barHeight: CGFloat = 52
            let menuHeight = MessageContextAction.estimatedMenuHeight(count: actions.count)
            let layout = MessageContextMenuLayout.resolve(
                messageFrame: messageFrame,
                reactionBarHeight: barHeight,
                menuHeight: menuHeight,
                safeArea: safeArea
            )

            ZStack(alignment: .topLeading) {
                // The transcript stays visible behind, blurred — you can still
                // see the conversation you are acting inside.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .opacity(hasAppeared ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
                    // Read last. It is on top of the ZStack's z-order but it
                    // is the least interesting thing here, and announcing
                    // "Close menu" before naming the message left no clue what
                    // the menu had been opened on.
                    .accessibilitySortPriority(-1)

                VStack(alignment: presentation.isOutgoing ? .trailing : .leading,
                       spacing: MessageContextMenuLayout.spacing) {
                    reactionBar
                        .frame(height: barHeight)

                    // The message, exactly as it was drawn a moment ago.
                    Image(uiImage: presentation.snapshot)
                        .resizable()
                        .frame(width: messageFrame.width, height: messageFrame.height)
                        // Tapping the lifted message dismisses, so it must not
                        // swallow the touch on its way to the backdrop.
                        .allowsHitTesting(false)
                        .accessibilityLabel("Selected message")

                    MessageContextActionList(
                        actions: actions,
                        isTrailingAligned: presentation.isOutgoing,
                        scrolls: layout.isScrollRequired,
                        maxHeight: safeArea.height - messageFrame.height - barHeight
                            - MessageContextMenuLayout.spacing * 2
                            - MessageContextMenuLayout.screenMargin * 2,
                        onSelect: onAction
                    )
                }
                .frame(width: messageFrame.width, alignment: presentation.isOutgoing ? .trailing : .leading)
                // Offset from the group's top-left rather than `.position`.
                //
                // `.position` expands the view it modifies to fill the parent,
                // so the stack became a full-screen layer covering the backdrop
                // and swallowing every tap meant to dismiss. It also centres,
                // which meant deriving the message's placement from half the
                // difference between the bar and menu heights — where what the
                // layout actually computes, and what has to be honoured, is the
                // top of the group.
                .offset(
                    x: messageFrame.minX,
                    y: messageFrame.minY - barHeight - MessageContextMenuLayout.spacing
                        + layout.verticalOffset
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Scale and fade from the message's own position, so the menu
                // grows out of what was pressed rather than appearing over it.
                .scaleEffect(hasAppeared ? 1 : 0.94, anchor: .center)
                .opacity(hasAppeared ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        // The two-finger scrub. Every other way out of this menu is a tap on
        // something, and a VoiceOver user has no way to aim at the backdrop.
        .accessibilityAction(.escape) { onDismiss() }
        .onAppear {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                hasAppeared = true
            }
        }
    }

    private var reactionBar: some View {
        HStack(spacing: 6) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 30))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React with \(emoji)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.08)) }
        .sanchrShadow(0.18, radius: 12, y: 4)
        // The bar is wider than a short message; let it overhang rather than
        // squeezing the emoji.
        .fixedSize()
    }
}
