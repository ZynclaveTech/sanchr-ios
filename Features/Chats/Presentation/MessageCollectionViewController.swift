import UIKit
import SwiftUI
import SanchrShared

// MARK: - Section & Item Models

enum MessageListSection: Hashable {
    /// Identity is the calendar day, which is stable and unique. The display
    /// title ("Today", "Yesterday", a formatted date) is deliberately NOT part
    /// of identity: it is relative to the current date, so when midnight passes
    /// while the chat is open, yesterday's messages and today's new ones would
    /// both title "Today" — two sections with identical identifiers, which
    /// crashes the diffable data source. Excluded from Hashable/Equatable so a
    /// title change (Today -> Yesterday) never churns section identity either.
    case messages(day: Date, title: String)

    static func == (lhs: MessageListSection, rhs: MessageListSection) -> Bool {
        switch (lhs, rhs) {
        case (.messages(let a, _), .messages(let b, _)):
            return a == b
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .messages(let day, _):
            hasher.combine(day)
        }
    }
}

/// The message a bubble is answering, resolved for display.
///
/// Resolved once per snapshot rather than looked up inside the bubble: the
/// bubble has no access to the transcript, and doing it per cell would be a
/// dictionary lookup on every scroll.
struct ReplyQuote: Hashable {
    /// Whether the quoted message was sent by us, so the bubble can say "You".
    let quotedIsOutgoing: Bool
    /// One-line description of the quoted content.
    let preview: String
}

struct MessageItem: Hashable {
    let message: Message
    let isGroupedWithPrev: Bool
    let isGroupedWithNext: Bool
    let uploadProgress: Double?
    let uploadLabel: String?
    let isUnreadDivider: Bool
    let replyQuote: ReplyQuote?

    init(
        message: Message,
        isGroupedWithPrev: Bool,
        isGroupedWithNext: Bool,
        uploadProgress: Double?,
        uploadLabel: String?,
        isUnreadDivider: Bool = false,
        replyQuote: ReplyQuote? = nil
    ) {
        self.replyQuote = replyQuote
        self.message         = message
        self.isGroupedWithPrev = isGroupedWithPrev
        self.isGroupedWithNext = isGroupedWithNext
        self.uploadProgress  = uploadProgress
        self.uploadLabel     = uploadLabel
        self.isUnreadDivider = isUnreadDivider
    }

    func hash(into hasher: inout Hasher) {
        isUnreadDivider ? hasher.combine("__unread_divider__") : hasher.combine(message.id)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.isUnreadDivider && rhs.isUnreadDivider { return true }
        if lhs.isUnreadDivider || rhs.isUnreadDivider { return false }
        return lhs.message.id == rhs.message.id
    }

    /// Synthetic item used as the "New Messages" divider.
    static let unreadDivider = MessageItem(
        message: Message(
            id: "__unread_divider__",
            conversationId: "", senderId: "",
            timestamp: .distantPast,
            content: .text(""),
            status: .sent,
            isOutgoing: false
        ),
        isGroupedWithPrev: false,
        isGroupedWithNext: false,
        uploadProgress: nil,
        uploadLabel: nil,
        isUnreadDivider: true
    )
}

private struct MessageItemRenderSignature: Hashable {
    let id: String
    let content: MessageContentRenderSignature
    let timestamp: Date
    let status: Message.DeliveryStatus
    let isOutgoing: Bool
    let replyToMessageId: String?
    let replyQuote: ReplyQuote?
    let reactions: [MessageReactionRenderSignature]
    let isGroupedWithPrev: Bool
    let isGroupedWithNext: Bool
    let uploadProgress: Double?
    let uploadLabel: String?
}

private enum MessageContentRenderSignature: Hashable {
    case text(String)
    case image([MediaAttachmentRenderSignature])
    case video([MediaAttachmentRenderSignature])
    case audio([MediaAttachmentRenderSignature])
    case document([MediaAttachmentRenderSignature])
    case location(latitude: Double, longitude: Double)
    case contact(name: String, phoneNumber: String)
    case system(Message.SystemEvent)
}

private struct MediaAttachmentRenderSignature: Hashable {
    let url: String
    let thumbnailURL: String?
    let mimeType: String
    let sizeBytes: Int64
    let caption: String?
    let width: Int?
    let height: Int?
    let durationSeconds: Double?
    let blurHash: String?
    let filename: String?
    let isVoiceMessage: Bool?
    let audioDurationMs: Int?
    let audioWaveform: [Float]?
    /// Included so consuming a view-once item actually refreshes the cell.
    /// Without it the bubble keeps rendering its pre-consumption state.
    let isViewOnce: Bool?
}

private struct MessageReactionRenderSignature: Hashable {
    let emoji: String
    let userId: String
}

private extension MessageItem {
    var renderSignature: MessageItemRenderSignature {
        MessageItemRenderSignature(
            id: message.id,
            content: message.renderContentSignature,
            timestamp: message.timestamp,
            status: message.status,
            isOutgoing: message.isOutgoing,
            replyToMessageId: message.replyToMessageId,
            replyQuote: replyQuote,
            reactions: message.renderReactionSignature,
            isGroupedWithPrev: isGroupedWithPrev,
            isGroupedWithNext: isGroupedWithNext,
            uploadProgress: uploadProgress,
            uploadLabel: uploadLabel
        )
    }
}

private extension Message.MediaAttachments {
    /// Signature over *every* attachment, in order.
    ///
    /// The diffable data source reconfigures a cell only when this changes, so
    /// signing just the first would leave an album that gained, lost or
    /// reordered members rendering its old layout.
    var renderSignature: [MediaAttachmentRenderSignature] {
        items.map(\.renderSignature)
    }
}

private extension Message {
    var renderContentSignature: MessageContentRenderSignature {
        switch content {
        case .text(let text):
            return .text(text)
        case .image(let media):
            return .image(media.renderSignature)
        case .video(let media):
            return .video(media.renderSignature)
        case .audio(let media):
            return .audio(media.renderSignature)
        case .document(let media):
            return .document(media.renderSignature)
        case .location(let latitude, let longitude):
            return .location(latitude: latitude, longitude: longitude)
        case .contact(let name, let phoneNumber):
            return .contact(name: name, phoneNumber: phoneNumber)
        case .system(let event):
            return .system(event)
        }
    }

    var renderReactionSignature: [MessageReactionRenderSignature] {
        reactions
            .map { MessageReactionRenderSignature(emoji: $0.emoji, userId: $0.userId) }
            .sorted {
                ($0.emoji, $0.userId) < ($1.emoji, $1.userId)
            }
    }
}

private extension Message.MediaAttachment {
    var renderSignature: MediaAttachmentRenderSignature {
        MediaAttachmentRenderSignature(
            url: url.absoluteString,
            thumbnailURL: thumbnailURL?.absoluteString,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            caption: caption,
            width: width,
            height: height,
            durationSeconds: durationSeconds,
            blurHash: blurHash,
            filename: filename,
            isVoiceMessage: isVoiceMessage,
            audioDurationMs: audioDurationMs,
            audioWaveform: audioWaveform,
            isViewOnce: isViewOnce
        )
    }
}

private struct VisibleAnchor {
    let messageId: String
    let topOffset: CGFloat
}

private final class ObservedCollectionView: UICollectionView {
    var onContentSizeChange: ((CGSize, CGSize) -> Void)?

    override var contentSize: CGSize {
        didSet {
            guard oldValue != contentSize else { return }
            onContentSizeChange?(oldValue, contentSize)
        }
    }
}

// MARK: - MessageCollectionViewController

/// Normal (non-flipped) UICollectionView for chat messages.
/// Uses `viewIsAppearing` to scroll to bottom BEFORE the view becomes visible —
/// this is the only reliable timing where geometry is final but the user can't
/// see the view yet. No alpha hacks, no flipping, no timing races.
final class MessageCollectionViewController: UIViewController {

    // MARK: - Callbacks

    var onReplyToMessage: ((Message) -> Void)?
    var onReactToMessage: ((String, String) -> Void)?
    var onDeleteMessage: ((Message) -> Void)?
    var onForwardMessage: ((Message) -> Void)?
    var onMediaAction: ((MediaMessageAction, Message) -> Void)?
    var onLongPressMessage: ((MessageContextPresentation) -> Void)?

    /// A long press that is waiting for the keyboard to finish leaving before
    /// its message is snapshotted. See `presentContextMenu(for:cell:)`.
    private var pendingContextMenu: (message: Message, cell: UICollectionViewCell)?
    var onRetryMessage: ((Message) -> Void)?
    var onScrolledToBottom: ((Bool) -> Void)?
    var onNewMessageCountWhileScrolled: ((Int) -> Void)?
    var onLoadMore: (() -> Void)?
    var onInitialContentPresented: (() -> Void)?
    /// Forwarded from `MessageBubble.onBubbleTap`. The view model owns the
    /// routing decision; this controller just plumbs the payload upward.
    var onBubbleTap: ((MessageInteraction) -> Void)?
    var voicePlayback: VoicePlaybackController = VoicePlaybackController()

    // MARK: - Views

    private var collectionView: ObservedCollectionView!

    // MARK: - State

    private var dataSource: UICollectionViewDiffableDataSource<MessageListSection, MessageItem>!
    private var wasAtBottom: Bool = true
    private var pendingNewMessageCount: Int = 0
    private var lastItemCount: Int = 0
    private var isLoadingMore: Bool = false
    private var lastRenderedItemSignatures: [String: MessageItemRenderSignature] = [:]
    private var lastAppliedTranscriptVersion: UInt64?
    private var lastAppliedUploadsVersion: UInt64?
    private var lastHandledScrollCommand: TranscriptScrollCommand?
    private var pendingScrollCommand: TranscriptScrollCommand?
    private var pendingInitialBottomPresentation = false
    private var lastMessageIDs: [String] = []
    private var hasAppliedFirstPopulatedSnapshot = false
    private var hasReportedInitialContentPresentation = false
    private var isMaintainingInitialBottomAnchor = false
    private var initialBottomAnchorReleaseTask: Task<Void, Never>?
    private var lastObservedPinnedContentHeight: CGFloat = 0
    private var hasConfiguredInteractivePopPriority = false

    /// Pending snapshot to apply after viewDidLoad.
    private var pendingRenderInput: TranscriptRenderInput?

    /// ID of the first unread message. When set, a "New Messages" divider
    /// is injected immediately above that message in the snapshot.
    /// Set from `TranscriptRenderInput.firstUnreadMessageId` by the SwiftUI bridge.
    var firstUnreadMessageId: String?

    // MARK: - Swipe-to-Reply

    private let swipeThreshold: CGFloat = 60

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )

        if let pending = pendingRenderInput {
            pendingRenderInput = nil
            update(renderInput: pending)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureInteractivePopGesturePriorityIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        guard collectionView != nil else { return }

        if shouldPinToBottomOnLayout {
            scrollToBottomImmediate()
            scheduleInitialBottomAnchorRelease()
        }

        if pendingInitialBottomPresentation, lastItemCount > 0 {
            collectionView.alpha = 1
            pendingInitialBottomPresentation = false
            notifyInitialContentPresentedIfNeeded()
        } else if collectionView.alpha == 0,
                  !pendingInitialBottomPresentation,
                  !isWaitingForInitialBottomContent
        {
            collectionView.alpha = 1
            notifyInitialContentPresentedIfNeeded()
        }
    }

    func update(renderInput: TranscriptRenderInput) {
        guard dataSource != nil else {
            pendingRenderInput = renderInput
            return
        }

        let didApplySnapshot: Bool
        if lastAppliedTranscriptVersion != renderInput.version {
            lastAppliedTranscriptVersion = renderInput.version
            // A full snapshot apply already pulls the freshest upload state
            // through the store, so sync the uploads watermark here too.
            lastAppliedUploadsVersion = renderInput.uploadsVersion
            didApplySnapshot = true
            applySnapshot(
                sections: renderInput.sections,
                uploads: renderInput.uploads
            )
        } else if lastAppliedUploadsVersion != renderInput.uploadsVersion {
            lastAppliedUploadsVersion = renderInput.uploadsVersion
            reconfigureUploadItems(uploads: renderInput.uploads)
            didApplySnapshot = false
        } else {
            didApplySnapshot = false
        }

        if let scrollCommand = renderInput.scrollCommand,
           scrollCommand != lastHandledScrollCommand
        {
            lastHandledScrollCommand = scrollCommand
            pendingScrollCommand = scrollCommand
            if !didApplySnapshot {
                _ = performPendingScrollCommandIfPossible()
            }
        }
    }

    // MARK: - Layout

    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfig.showsSeparators = false
        listConfig.backgroundColor = .clear
        listConfig.headerMode = .supplementary
        return UICollectionViewCompositionalLayout.list(using: listConfig)
    }

    // MARK: - Collection View Configuration

    private func configureCollectionView() {
        let layout = Self.makeLayout()
        let cv = ObservedCollectionView(frame: view.bounds, collectionViewLayout: layout)
        cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cv.backgroundColor = .clear
        cv.keyboardDismissMode = .interactive
        cv.alwaysBounceVertical = true
        cv.contentInsetAdjustmentBehavior = .automatic
        cv.delegate = self
        cv.onContentSizeChange = { [weak self] oldSize, newSize in
            self?.handleCollectionContentSizeChange(from: oldSize, to: newSize)
        }

        // Hidden until viewIsAppearing scrolls to bottom
        cv.alpha = 0

        view.addSubview(cv)
        collectionView = cv
    }

    // MARK: - Data Source

    private func configureDataSource() {
        let cellRegistration = makeCellRegistration()
        let headerRegistration = makeHeaderRegistration()

        dataSource = UICollectionViewDiffableDataSource<MessageListSection, MessageItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration, for: indexPath, item: item)
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(
                    using: headerRegistration, for: indexPath)
            }
            return nil
        }
    }

    // MARK: - Cell Registration

    private func makeCellRegistration() -> UICollectionView.CellRegistration<UICollectionViewCell, MessageItem> {
        UICollectionView.CellRegistration<UICollectionViewCell, MessageItem> { [weak self] cell, _, item in
            self?.applyCellConfiguration(cell, item: item)
        }
    }

    /// Single source of truth for bubble cell content — called from both
    /// the registration block on initial dequeue AND the visible-cell
    /// reconfigure path for upload-progress updates. Keeps both render
    /// paths aligned so an upload bubble looks identical whether its cell
    /// was just created or patched in place.
    private func applyCellConfiguration(_ cell: UICollectionViewCell, item: MessageItem) {
        if item.isUnreadDivider {
            cell.contentConfiguration = UIHostingConfiguration {
                UnreadDividerRow()
            }
            .margins(.all, 0)
            .background(.clear)
            return
        }

        let voicePlayback = self.voicePlayback
        cell.contentConfiguration = UIHostingConfiguration { [weak self] in
            VStack(alignment: item.message.isOutgoing ? .trailing : .leading, spacing: 4) {
                MessageBubble(
                    message: item.message,
                    replyQuote: item.replyQuote,
                    uploadProgress: item.uploadProgress,
                    uploadLabel: item.uploadLabel,
                    hideTimestamp: item.isGroupedWithNext,
                    isGroupedWithPrev: item.isGroupedWithPrev,
                    isGroupedWithNext: item.isGroupedWithNext,
                    voicePlayback: voicePlayback,
                    onBubbleTap: { interaction in
                        self?.onBubbleTap?(interaction)
                    }
                )

                if !item.message.reactions.isEmpty {
                    ReactionPillsRow(
                        reactions: item.message.reactions,
                        isOutgoing: item.message.isOutgoing
                    ) { emoji in
                        self?.onReactToMessage?(emoji, item.message.id)
                    }
                }
            }
        }
        .margins(.horizontal, SanchrExportMetrics.sectionHorizontal)
        .margins(.vertical, item.isGroupedWithPrev ? 2 : 6)
        .background(.clear)

        attachSwipeGesture(to: cell, message: item.message)
    }

    // MARK: - Header Registration

    private func makeHeaderRegistration() -> UICollectionView.SupplementaryRegistration<UICollectionViewCell> {
        UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] supplementaryView, _, indexPath in
            guard let self,
                  let sectionIdentifier = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }

            let title: String
            switch sectionIdentifier {
            case .messages(_, let sectionTitle):
                title = sectionTitle
            }

            supplementaryView.contentConfiguration = UIHostingConfiguration {
                HStack {
                    Spacer()
                    Text(title)
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.medium)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(SanchrExportColors.surface)
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
                        .overlay {
                            Capsule()
                                .stroke(SanchrExportColors.line, lineWidth: 1)
                        }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .margins(.all, 0)
            .background(.clear)
        }
    }

    // MARK: - Snapshot Application

    /// Resolves what a reply is answering, if the target is in the transcript.
    static func quote(for message: Message, in byId: [String: Message]) -> ReplyQuote? {
        guard let replyId = message.replyToMessageId, let quoted = byId[replyId] else {
            return nil
        }
        return ReplyQuote(
            quotedIsOutgoing: quoted.isOutgoing,
            preview: ChatInputBarView.replyPreviewText(quoted)
        )
    }

    func applySnapshot(sections: [MessageSection], uploads: UploadProgressStore) {
        // One index per snapshot. A reply whose target is not loaded (older
        // than the window, or deleted) simply resolves to nil and the bubble
        // falls back to saying only that it is a reply.
        let byId = Dictionary(
            sections.lazy.flatMap(\.messages).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard dataSource != nil else {
            pendingRenderInput = TranscriptRenderInput(
                sections: sections,
                uploads: uploads,
                uploadsVersion: uploads.version,
                version: lastAppliedTranscriptVersion ?? 0,
                scrollCommand: pendingScrollCommand,
                firstUnreadMessageId: firstUnreadMessageId
            )
            return
        }

        var snapshot = NSDiffableDataSourceSnapshot<MessageListSection, MessageItem>()
        var newRenderedItemSignatures: [String: MessageItemRenderSignature] = [:]
        var itemsToReconfigure: [MessageItem] = []
        let previousItemCount = lastItemCount
        let previousMessageIDs = lastMessageIDs
        var newMessageIDs: [String] = []
        let groupingThreshold: TimeInterval = 180

        for section in sections {
            let sectionId = MessageListSection.messages(day: section.id, title: section.title)
            snapshot.appendSections([sectionId])

            var sectionItems: [MessageItem] = []

            for (index, message) in section.messages.enumerated() {
                let prev = index > 0 ? section.messages[index - 1] : nil
                let next = index < section.messages.count - 1 ? section.messages[index + 1] : nil
                let isFirstUnread = message.id == firstUnreadMessageId

                // Never visually group the first unread message with its predecessor
                // since the divider row separates them.
                let isGroupedWithPrev = !isFirstUnread
                    && prev?.senderId == message.senderId
                    && prev?.isOutgoing == message.isOutgoing
                    && message.timestamp.timeIntervalSince(prev?.timestamp ?? .distantPast) < groupingThreshold

                let isGroupedWithNext = next?.senderId == message.senderId
                    && next?.isOutgoing == message.isOutgoing
                    && (next?.timestamp ?? .distantFuture).timeIntervalSince(message.timestamp) < groupingThreshold

                if isFirstUnread { sectionItems.append(.unreadDivider) }
                sectionItems.append(MessageItem(
                    message: message,
                    isGroupedWithPrev: isGroupedWithPrev,
                    isGroupedWithNext: isGroupedWithNext,
                    uploadProgress: uploads.progress(for: message.id),
                    uploadLabel: uploads.statusLabel(for: message.id),
                    replyQuote: Self.quote(for: message, in: byId)
                ))
            }

            for item in sectionItems {
                guard !item.isUnreadDivider else { continue }
                newMessageIDs.append(item.message.id)
                let signature = item.renderSignature
                if lastRenderedItemSignatures[item.message.id] != nil,
                   lastRenderedItemSignatures[item.message.id] != signature
                {
                    itemsToReconfigure.append(item)
                }
                newRenderedItemSignatures[item.message.id] = signature
            }

            snapshot.appendItems(sectionItems, toSection: sectionId)
        }

        if !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }

        let newItemCount = snapshot.numberOfItems
        let preserveVisibleAnchor = shouldPreserveVisibleAnchor(
            previousMessageIDs: previousMessageIDs,
            newMessageIDs: newMessageIDs
        )
        let visibleAnchor = preserveVisibleAnchor ? captureVisibleAnchor() : nil
        let isFirstPopulatedLoad = !hasAppliedFirstPopulatedSnapshot && newItemCount > 0
        let animate = !pendingInitialBottomPresentation
            && !isFirstPopulatedLoad
            && newItemCount != previousItemCount
            && previousItemCount > 0
        lastItemCount = newItemCount
        lastRenderedItemSignatures = newRenderedItemSignatures
        lastMessageIDs = newMessageIDs

        if isFirstPopulatedLoad {
            hasAppliedFirstPopulatedSnapshot = true
            dataSource.applySnapshotUsingReloadData(snapshot)
            collectionView.layoutIfNeeded()
            if !performPendingScrollCommandIfPossible() {
                if wasAtBottom {
                    scrollToBottom(animated: false)
                }
                collectionView.alpha = 1
            }
            notifyInitialContentPresentedIfNeeded()
            return
        }

        dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
            guard let self else { return }

            self.collectionView.layoutIfNeeded()

            if self.performPendingScrollCommandIfPossible() {
                return
            }

            if let visibleAnchor {
                self.restoreVisibleAnchor(visibleAnchor)
                return
            }

            if !self.hasAppliedFirstPopulatedSnapshot, newItemCount == 0 {
                // Empty conversation — still need to reveal the collection view
                // and dismiss the "Opening conversation…" overlay.
                self.collectionView.alpha = 1
                self.notifyInitialContentPresentedIfNeeded()
                return
            }

            if self.wasAtBottom {
                self.scrollToBottom(animated: animate)
            } else {
                let addedCount = newItemCount - previousItemCount
                if addedCount > 0 {
                    self.pendingNewMessageCount += addedCount
                    self.onNewMessageCountWhileScrolled?(self.pendingNewMessageCount)
                }
            }

            if self.collectionView.alpha == 0, !self.pendingInitialBottomPresentation {
                self.collectionView.alpha = 1
            }

            if self.collectionView.alpha > 0 {
                self.notifyInitialContentPresentedIfNeeded()
            }
        }
    }

    private func notifyInitialContentPresentedIfNeeded() {
        guard !hasReportedInitialContentPresentation else { return }
        hasReportedInitialContentPresentation = true
        onInitialContentPresented?()
    }

    // MARK: - Reconfigure-only upload updates
    //
    // Fast path for byte-progress callbacks: the transcript version hasn't
    // moved but `uploads.version` has. We refresh only the visible cells
    // whose messages are active uploads — directly rewriting their
    // UIHostingConfiguration in place. The dataSource snapshot is NOT
    // touched, so the diff engine never runs, no animations fire, and
    // invisible cells (which aren't rendered anyway) pick up fresh state
    // when they're next dequeued or on the next full snapshot apply.
    private func reconfigureUploadItems(uploads: UploadProgressStore) {
        guard dataSource != nil else { return }

        let activeIds = uploads.activeUploadIds
        guard !activeIds.isEmpty else { return }

        let visibleIndexPaths = collectionView.indexPathsForVisibleItems
        guard !visibleIndexPaths.isEmpty else { return }

        for indexPath in visibleIndexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  !item.isUnreadDivider,
                  activeIds.contains(item.message.id),
                  let cell = collectionView.cellForItem(at: indexPath) else { continue }

            let refreshed = MessageItem(
                message: item.message,
                isGroupedWithPrev: item.isGroupedWithPrev,
                isGroupedWithNext: item.isGroupedWithNext,
                uploadProgress: uploads.progress(for: item.message.id),
                uploadLabel: uploads.statusLabel(for: item.message.id),
                replyQuote: item.replyQuote
            )

            applyCellConfiguration(cell, item: refreshed)
            lastRenderedItemSignatures[item.message.id] = refreshed.renderSignature
        }
    }

    // MARK: - Scrolling

    private var maxContentOffsetY: CGFloat {
        max(0, collectionView.contentSize.height
            - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom)
    }

    private var minContentOffsetY: CGFloat {
        -collectionView.adjustedContentInset.top
    }

    private var shouldPinToBottomOnLayout: Bool {
        (pendingInitialBottomPresentation && lastItemCount > 0)
            || (isMaintainingInitialBottomAnchor && lastItemCount > 0)
            || (wasAtBottom
                && collectionView.alpha > 0
                && !collectionView.isTracking
                && !collectionView.isDragging
                && !collectionView.isDecelerating)
    }

    private var isWaitingForInitialBottomContent: Bool {
        guard case .initialBottom = pendingScrollCommand else { return false }
        return lastItemCount == 0
    }

    private func handleCollectionContentSizeChange(from oldSize: CGSize, to newSize: CGSize) {
        guard collectionView != nil else { return }
        guard abs(oldSize.height - newSize.height) > 0.5 || abs(oldSize.width - newSize.width) > 0.5 else {
            return
        }

        let shouldPreserveBottom =
            lastItemCount > 0
            && collectionView.window != nil
            && !collectionView.isTracking
            && !collectionView.isDragging
            && !collectionView.isDecelerating
            && (isMaintainingInitialBottomAnchor || wasAtBottom)

        guard shouldPreserveBottom else {
            if isMaintainingInitialBottomAnchor {
                scheduleInitialBottomAnchorRelease()
            }
            return
        }

        collectionView.layoutIfNeeded()
        scrollToBottomImmediate()

        if isMaintainingInitialBottomAnchor {
            scheduleInitialBottomAnchorRelease()
        }
    }

    private func configureInteractivePopGesturePriorityIfNeeded() {
        guard !hasConfiguredInteractivePopPriority,
              let popGesture = navigationController?.interactivePopGestureRecognizer
        else {
            return
        }

        collectionView.panGestureRecognizer.require(toFail: popGesture)
        hasConfiguredInteractivePopPriority = true
    }

    private func scrollToBottomImmediate() {
        collectionView.setContentOffset(
            CGPoint(x: 0, y: maxContentOffsetY),
            animated: false
        )
    }

    func scrollToBottom(animated: Bool) {
        pendingInitialBottomPresentation = false
        wasAtBottom = true
        collectionView.alpha = 1
        collectionView.setContentOffset(
            CGPoint(x: 0, y: maxContentOffsetY),
            animated: animated
        )
    }

    private func beginInitialBottomAnchorMaintenance() {
        isMaintainingInitialBottomAnchor = true
        lastObservedPinnedContentHeight = collectionView.contentSize.height
        scheduleInitialBottomAnchorRelease()
    }

    private func endInitialBottomAnchorMaintenance() {
        isMaintainingInitialBottomAnchor = false
        initialBottomAnchorReleaseTask?.cancel()
        initialBottomAnchorReleaseTask = nil
    }

    private func scheduleInitialBottomAnchorRelease() {
        guard isMaintainingInitialBottomAnchor else { return }

        let contentHeight = collectionView.contentSize.height
        let contentHeightDidChange = abs(contentHeight - lastObservedPinnedContentHeight) > 0.5
        lastObservedPinnedContentHeight = contentHeight

        initialBottomAnchorReleaseTask?.cancel()
        initialBottomAnchorReleaseTask = Task { @MainActor [weak self] in
            let delayNanoseconds: UInt64 = contentHeightDidChange ? 300_000_000 : 180_000_000
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.endInitialBottomAnchorMaintenance()
        }
    }

    @discardableResult
    func scrollToMessage(id: String) -> Bool {
        guard let snapshot = dataSource?.snapshot() else { return false }
        for item in snapshot.itemIdentifiers where item.message.id == id {
            guard let indexPath = dataSource.indexPath(for: item) else { continue }
            pendingInitialBottomPresentation = false
            wasAtBottom = false
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)

            if let cell = collectionView.cellForItem(at: indexPath) {
                UIView.animate(withDuration: 0.2) {
                    cell.contentView.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.3)
                } completion: { _ in
                    UIView.animate(withDuration: 0.6) {
                        cell.contentView.backgroundColor = .clear
                    }
                }
            }
            return true
        }
        return false
    }

    @discardableResult
    private func performPendingScrollCommandIfPossible() -> Bool {
        guard let command = pendingScrollCommand else { return false }

        switch command {
        case .initialBottom:
            guard lastItemCount > 0 else { return false }
            pendingInitialBottomPresentation = true
            wasAtBottom = true
            beginInitialBottomAnchorMaintenance()
            pendingNewMessageCount = 0
            onNewMessageCountWhileScrolled?(0)
            pendingScrollCommand = nil
            collectionView.layoutIfNeeded()
            scrollToBottomImmediate()
            collectionView.alpha = 1
            pendingInitialBottomPresentation = false
            return true

        case .manualBottom:
            pendingScrollCommand = nil
            pendingNewMessageCount = 0
            onNewMessageCountWhileScrolled?(0)
            endInitialBottomAnchorMaintenance()
            scrollToBottom(animated: true)
            return true

        case .message(let id, _):
            endInitialBottomAnchorMaintenance()
            guard scrollToMessage(id: id) else { return false }
            pendingScrollCommand = nil
            collectionView.alpha = 1
            return true
        }
    }

    private func shouldPreserveVisibleAnchor(
        previousMessageIDs: [String],
        newMessageIDs: [String]
    ) -> Bool {
        guard !wasAtBottom,
              !previousMessageIDs.isEmpty,
              newMessageIDs.count > previousMessageIDs.count,
              newMessageIDs.last == previousMessageIDs.last,
              newMessageIDs.first != previousMessageIDs.first
        else {
            return false
        }
        return true
    }

    private func captureVisibleAnchor() -> VisibleAnchor? {
        let topVisibleIndexPath = collectionView.indexPathsForVisibleItems.min {
            if $0.section == $1.section {
                return $0.item < $1.item
            }
            return $0.section < $1.section
        }

        guard let topVisibleIndexPath,
              let item = dataSource.itemIdentifier(for: topVisibleIndexPath),
              let frame = frameForItem(at: topVisibleIndexPath)
        else {
            return nil
        }

        return VisibleAnchor(
            messageId: item.message.id,
            topOffset: frame.minY - collectionView.contentOffset.y
        )
    }

    private func restoreVisibleAnchor(_ anchor: VisibleAnchor) {
        guard let snapshot = dataSource?.snapshot() else { return }

        guard let item = snapshot.itemIdentifiers.first(where: { $0.message.id == anchor.messageId }),
              let indexPath = dataSource.indexPath(for: item),
              let frame = frameForItem(at: indexPath)
        else {
            return
        }

        let desiredOffsetY = min(
            max(frame.minY - anchor.topOffset, minContentOffsetY),
            maxContentOffsetY
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: desiredOffsetY), animated: false)
    }

    private func frameForItem(at indexPath: IndexPath) -> CGRect? {
        if let cell = collectionView.cellForItem(at: indexPath) {
            return cell.frame
        }
        return collectionView.layoutAttributesForItem(at: indexPath)?.frame
    }

    // MARK: - Context Menu

    /// What a media message can do beyond the actions any message has.
    ///
    /// Reachable from the transcript rather than only from inside the viewer,
    /// so a photo can be saved or shared without opening it first — and so the
    /// video player does not have to carry a second toolbar to offer them.
    enum MediaMessageAction {
        case saveToPhotos
        case share
        case copy
    }

    private func makeContextMenu(for message: Message) -> UIMenu {
        var actions: [UIMenuElement] = []

        if case .text(let text) = message.content {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            })
        }

        // Media actions. Deliberately first: on a photo or a video they are the
        // reason most people open this menu.
        if message.content.isSaveableMedia {
            actions.append(UIAction(
                title: "Save to Photos",
                image: UIImage(systemName: "square.and.arrow.down")
            ) { [weak self] _ in
                self?.onMediaAction?(.saveToPhotos, message)
            })
            actions.append(UIAction(
                title: "Share",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                self?.onMediaAction?(.share, message)
            })
            actions.append(UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.onMediaAction?(.copy, message)
            })
        }

        actions.append(UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            self?.onReplyToMessage?(message)
        })

        actions.append(UIAction(title: "Forward", image: UIImage(systemName: "arrowshape.turn.up.right")) { [weak self] _ in
            self?.onForwardMessage?(message)
        })

        let quickEmojis = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F64F}"]
        let reactionActions = quickEmojis.map { emoji in
            UIAction(title: emoji) { [weak self] _ in
                self?.onReactToMessage?(emoji, message.id)
            }
        }
        actions.append(UIMenu(title: "React", image: UIImage(systemName: "face.smiling"), children: reactionActions))

        if message.status == .failed {
            actions.append(UIAction(
                title: "Retry",
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in
                self?.onRetryMessage?(message)
            })
        }

        if message.isOutgoing {
            actions.append(
                UIAction(
                    title: "Delete", image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.onDeleteMessage?(message)
                })
        }

        return UIMenu(children: actions)
    }

    // MARK: - Swipe-to-Reply Gesture

    private func attachSwipeGesture(to cell: UICollectionViewCell, message: Message) {
        cell.gestureRecognizers?.filter { $0 is SwipeToReplyGesture }.forEach {
            cell.removeGestureRecognizer($0)
        }

        let pan = SwipeToReplyGesture(
            message: message,
            threshold: swipeThreshold
        ) { [weak self] msg in
            self?.onReplyToMessage?(msg)
        }
        pan.delegate = self
        cell.addGestureRecognizer(pan)

        attachLongPressGesture(to: cell, message: message)
    }

    /// Long press opens our own context menu rather than UIKit's.
    ///
    /// `UIContextMenuInteraction` cannot put anything above its preview, so a
    /// reaction bar has nowhere to go — which is why the previous attempt put
    /// the bar *in place of* the message. Signal reached the same conclusion
    /// and wrote its own context menu for it.
    private func attachLongPressGesture(to cell: UICollectionViewCell, message: Message) {
        cell.gestureRecognizers?
            .compactMap { $0 as? MessageLongPressGesture }
            .forEach { cell.removeGestureRecognizer($0) }

        let press = MessageLongPressGesture(message: message) { [weak self, weak cell] msg in
            guard let self, let cell else { return }
            self.presentContextMenu(for: msg, cell: cell)
        }
        press.delegate = self
        cell.addGestureRecognizer(press)
    }

    /// Long-press with the keyboard up.
    ///
    /// The keyboard would cover the menu, so it has to go. But dismissing it
    /// grows the transcript and moves the cell, and the snapshot's frame is
    /// what the menu is positioned by — taken too early, the lifted message is
    /// drawn where the cell *was*. So when there is a keyboard to dismiss, the
    /// menu waits for it to finish leaving.
    private func presentContextMenu(for message: Message, cell: UICollectionViewCell) {
        guard cell.window != nil else { return }

        if view.window?.endEditing(true) == true {
            pendingContextMenu = (message, cell)
        } else {
            emitContextMenu(for: message, cell: cell)
        }
    }

    @objc private func keyboardDidHide() {
        guard let pending = pendingContextMenu else { return }
        pendingContextMenu = nil
        // Layout has settled; the cell is where it is going to stay.
        emitContextMenu(for: pending.message, cell: pending.cell)
    }

    private func emitContextMenu(for message: Message, cell: UICollectionViewCell) {
        guard let window = cell.window else { return }

        // Snapshot rather than re-render: this is the cell as drawn, including
        // whatever async media had loaded by now.
        let renderer = UIGraphicsImageRenderer(bounds: cell.bounds)
        let snapshot = renderer.image { _ in
            cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: false)
        }

        onLongPressMessage?(
            MessageContextPresentation(
                id: message.id,
                message: message,
                snapshot: snapshot,
                sourceFrame: cell.convert(cell.bounds, to: window),
                isOutgoing: message.isOutgoing,
                isSaveableMedia: message.content.isSaveableMedia,
                canRetry: message.status == .failed
            )
        )
    }
}

// MARK: - UICollectionViewDelegate

extension MessageCollectionViewController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingInitialBottomPresentation = false
        endInitialBottomAnchorMaintenance()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isMaintainingInitialBottomAnchor,
           !scrollView.isTracking,
           !scrollView.isDragging,
           !scrollView.isDecelerating
        {
            wasAtBottom = true
            scheduleInitialBottomAnchorRelease()
            return
        }

        let offsetFromBottom = scrollView.contentSize.height
            - scrollView.contentOffset.y
            - scrollView.bounds.height
        let isAtBottom = offsetFromBottom < 50

        if isAtBottom != wasAtBottom {
            wasAtBottom = isAtBottom
            onScrolledToBottom?(isAtBottom)

            if isAtBottom {
                pendingNewMessageCount = 0
                onNewMessageCountWhileScrolled?(0)
            }
        }

        // Load more when near top
        if scrollView.contentOffset.y < 200 && !isLoadingMore {
            isLoadingMore = true
            onLoadMore?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isLoadingMore = false
            }
        }
    }

}

// MARK: - UIGestureRecognizerDelegate

extension MessageCollectionViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.x) > abs(velocity.y) * 1.5
    }
}

// MARK: - ReactionPillsRow

private struct ReactionPillsRow: View {
    let reactions: [Message.MessageReaction]
    let isOutgoing: Bool
    let onTapReaction: (String) -> Void

    private var grouped: [(emoji: String, count: Int)] {
        var dict: [String: Int] = [:]
        for r in reactions { dict[r.emoji, default: 0] += 1 }
        return dict.map { (emoji: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped, id: \.emoji) { item in
                Button {
                    onTapReaction(item.emoji)
                } label: {
                    HStack(spacing: 2) {
                        Text(item.emoji).font(.system(size: 14))
                        if item.count > 1 {
                            Text("\(item.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SanchrExportColors.surface)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().stroke(SanchrExportColors.line, lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Unread Divider

/// "— New Messages —" separator rendered above the first unread message.
private struct UnreadDividerRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(SanchrExportColors.line)
                .frame(height: 1)
            Text("New Messages")
                .font(SanchrTypography.captionSmall)
                .fontWeight(.semibold)
                .foregroundColor(SanchrColors.primary)
                .fixedSize()
            Rectangle()
                .fill(SanchrExportColors.line)
                .frame(height: 1)
        }
        .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - SwipeToReplyGesture

private final class SwipeToReplyGesture: UIPanGestureRecognizer {
    private let message: Message
    private let threshold: CGFloat
    private let onReply: (Message) -> Void
    private var replyIndicator: UIImageView?
    private var didTrigger = false

    init(message: Message, threshold: CGFloat, onReply: @escaping (Message) -> Void) {
        self.message = message
        self.threshold = threshold
        self.onReply = onReply
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(handlePan))
    }

    @objc private func handlePan() {
        guard let cell = view else { return }
        let translation = self.translation(in: cell)

        switch state {
        case .began:
            didTrigger = false
            addReplyIndicator(to: cell)

        case .changed:
            let swipeDistance: CGFloat
            if message.isOutgoing {
                swipeDistance = min(0, translation.x) * 0.5
            } else {
                swipeDistance = max(0, translation.x) * 0.5
            }

            cell.transform = CGAffineTransform(translationX: swipeDistance, y: 0)
            updateReplyIndicator(offset: swipeDistance)

            let absDistance = abs(swipeDistance)
            if absDistance >= threshold / 2 && !didTrigger {
                didTrigger = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }

        case .ended, .cancelled:
            let swipeDistance: CGFloat
            if message.isOutgoing {
                swipeDistance = min(0, translation.x) * 0.5
            } else {
                swipeDistance = max(0, translation.x) * 0.5
            }

            if abs(swipeDistance) >= threshold / 2 {
                onReply(message)
            }

            UIView.animate(
                withDuration: 0.35,
                delay: 0,
                usingSpringWithDamping: 0.7,
                initialSpringVelocity: 0.5
            ) {
                cell.transform = .identity
                self.replyIndicator?.alpha = 0
            } completion: { [weak self] _ in
                self?.replyIndicator?.removeFromSuperview()
                self?.replyIndicator = nil
            }

        default:
            break
        }
    }

    private func addReplyIndicator(to cell: UIView) {
        replyIndicator?.removeFromSuperview()

        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let image = UIImage(systemName: "arrowshape.turn.up.left.fill", withConfiguration: config)
        let indicator = UIImageView(image: image)
        indicator.tintColor = .secondaryLabel
        indicator.alpha = 0

        cell.addSubview(indicator)
        indicator.translatesAutoresizingMaskIntoConstraints = false

        if message.isOutgoing {
            NSLayoutConstraint.activate([
                indicator.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                indicator.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                indicator.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                indicator.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        replyIndicator = indicator
    }

    private func updateReplyIndicator(offset: CGFloat) {
        let progress = min(1.0, abs(offset) / (threshold / 2))
        replyIndicator?.alpha = progress
        let scale = 0.5 + progress * 0.5
        replyIndicator?.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

/// Long press that carries the message it was made for, so the handler does not
/// have to map a touch point back to an index path that may have moved.
private final class MessageLongPressGesture: UILongPressGestureRecognizer {
    private let message: Message
    private let onRecognized: (Message) -> Void

    init(message: Message, onRecognized: @escaping (Message) -> Void) {
        self.message = message
        self.onRecognized = onRecognized
        super.init(target: nil, action: nil)
        minimumPressDuration = 0.35
        addTarget(self, action: #selector(handle))
    }

    @objc private func handle() {
        // Fires on .began, while the finger is still down — the same moment
        // UIKit's own context menu commits, so it feels the same.
        guard state == .began else { return }
        onRecognized(message)
    }
}
