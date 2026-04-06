import UIKit
import SwiftUI

// MARK: - Section & Item Models

enum MessageListSection: Hashable {
    case messages(date: String)
}

struct MessageItem: Hashable {
    let message: Message
    let isGroupedWithPrev: Bool
    let isGroupedWithNext: Bool
    let uploadProgress: Double?
    let uploadLabel: String?

    func hash(into hasher: inout Hasher) { hasher.combine(message.id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.message.id == rhs.message.id }
}

// MARK: - MessageCollectionViewController

/// UICollectionViewController that renders chat messages using compositional layout,
/// diffable data source, and UIHostingConfiguration for SwiftUI bubble cells.
final class MessageCollectionViewController: UICollectionViewController {

    // MARK: - Callbacks

    var onReplyToMessage: ((Message) -> Void)?
    var onReactToMessage: ((String, String) -> Void)?
    var onScrolledToBottom: ((Bool) -> Void)?
    var onNewMessageCountWhileScrolled: ((Int) -> Void)?
    var onLoadMore: (() -> Void)?

    // MARK: - State

    private var dataSource: UICollectionViewDiffableDataSource<MessageListSection, MessageItem>!
    private var wasAtBottom: Bool = true
    private var pendingNewMessageCount: Int = 0
    private var isInitialLoad: Bool = true
    private var lastItemCount: Int = 0

    /// Tracks whether a load-more request is currently in flight to avoid duplicate calls.
    private var isLoadingMore: Bool = false

    // MARK: - Swipe-to-Reply

    private let swipeThreshold: CGFloat = 60

    // MARK: - Init

    init() {
        let layout = Self.makeLayout()
        super.init(collectionViewLayout: layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
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
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .automatic
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
            cell.contentConfiguration = UIHostingConfiguration {
                VStack(alignment: item.message.isOutgoing ? .trailing : .leading, spacing: 4) {
                    MessageBubble(
                        message: item.message,
                        uploadProgress: item.uploadProgress,
                        uploadLabel: item.uploadLabel,
                        hideTimestamp: item.isGroupedWithNext
                    )

                    if !item.message.reactions.isEmpty {
                        ReactionPillsRow(
                            reactions: item.message.reactions,
                            isOutgoing: item.message.isOutgoing
                        ) { [weak self] emoji in
                            self?.onReactToMessage?(emoji, item.message.id)
                        }
                    }
                }
            }
            .margins(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .margins(.vertical, item.isGroupedWithPrev ? 1 : 6)
            .background(.clear)

            // Swipe-to-reply gesture
            self?.attachSwipeGesture(to: cell, message: item.message)
        }
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
            case .messages(let date):
                title = date
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

    func applySnapshot(sections: [MessageSection], uploadProgress: [String: Double], uploadStatusLabel: [String: String]) {
        var snapshot = NSDiffableDataSourceSnapshot<MessageListSection, MessageItem>()

        for section in sections {
            let sectionId = MessageListSection.messages(date: section.title)
            snapshot.appendSections([sectionId])

            let items: [MessageItem] = section.messages.enumerated().map { index, message in
                let prev = index > 0 ? section.messages[index - 1] : nil
                let next = index < section.messages.count - 1 ? section.messages[index + 1] : nil

                let isGroupedWithPrev = prev?.senderId == message.senderId
                    && prev?.isOutgoing == message.isOutgoing
                    && message.timestamp.timeIntervalSince(prev?.timestamp ?? .distantPast) < 60

                let isGroupedWithNext = next?.senderId == message.senderId
                    && next?.isOutgoing == message.isOutgoing
                    && (next?.timestamp ?? .distantFuture).timeIntervalSince(message.timestamp) < 60

                return MessageItem(
                    message: message,
                    isGroupedWithPrev: isGroupedWithPrev,
                    isGroupedWithNext: isGroupedWithNext,
                    uploadProgress: uploadProgress[message.id],
                    uploadLabel: uploadStatusLabel[message.id]
                )
            }

            snapshot.appendItems(items, toSection: sectionId)
        }

        let newItemCount = snapshot.numberOfItems
        let animate = !isInitialLoad && newItemCount != lastItemCount
        lastItemCount = newItemCount

        dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
            guard let self else { return }
            if self.isInitialLoad {
                self.isInitialLoad = false
                self.scrollToBottom(animated: false)
            } else if self.wasAtBottom {
                self.scrollToBottom(animated: true)
            } else {
                // User is scrolled up — track new messages
                let addedCount = max(0, newItemCount - self.lastItemCount)
                if addedCount > 0 {
                    self.pendingNewMessageCount += addedCount
                    self.onNewMessageCountWhileScrolled?(self.pendingNewMessageCount)
                }
            }
        }
    }

    // MARK: - Scrolling

    func scrollToBottom(animated: Bool) {
        let lastSection = collectionView.numberOfSections - 1
        guard lastSection >= 0 else { return }
        let lastItem = collectionView.numberOfItems(inSection: lastSection) - 1
        guard lastItem >= 0 else { return }
        let indexPath = IndexPath(item: lastItem, section: lastSection)
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    func scrollToMessage(id: String) {
        guard let snapshot = dataSource?.snapshot() else { return }
        for item in snapshot.itemIdentifiers where item.message.id == id {
            guard let indexPath = dataSource.indexPath(for: item) else { continue }
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)

            // Flash highlight on the cell
            if let cell = collectionView.cellForItem(at: indexPath) {
                UIView.animate(withDuration: 0.2) {
                    cell.contentView.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.3)
                } completion: { _ in
                    UIView.animate(withDuration: 0.6) {
                        cell.contentView.backgroundColor = .clear
                    }
                }
            }
            break
        }
    }

    // MARK: - Scroll Detection

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
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
            // Reset after a short delay to allow the load to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isLoadingMore = false
            }
        }
    }

    // MARK: - Context Menu

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let message = item.message

        return UIContextMenuConfiguration(
            identifier: indexPath as NSCopying,
            previewProvider: { [weak self] in
                self?.makeReactionPreview(for: message)
            },
            actionProvider: { [weak self] _ in
                self?.makeContextMenu(for: message)
            }
        )
    }

    private func makeReactionPreview(for message: Message) -> UIViewController? {
        let quickEmojis = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F64F}"]
        let host = UIHostingController(rootView:
            HStack(spacing: 10) {
                ForEach(quickEmojis, id: \.self) { emoji in
                    Button {
                        // Handled via willPerformPreviewActionForMenuWith
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        )
        host.preferredContentSize = CGSize(width: 320, height: 60)
        host.view.backgroundColor = .clear
        return host
    }

    private func makeContextMenu(for message: Message) -> UIMenu {
        var actions: [UIMenuElement] = []

        // Copy action for text messages
        if case .text(let text) = message.content {
            let copy = UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = text
            }
            actions.append(copy)
        }

        // Reply
        let reply = UIAction(
            title: "Reply",
            image: UIImage(systemName: "arrowshape.turn.up.left")
        ) { [weak self] _ in
            self?.onReplyToMessage?(message)
        }
        actions.append(reply)

        // Forward
        let forward = UIAction(
            title: "Forward",
            image: UIImage(systemName: "arrowshape.turn.up.right")
        ) { _ in
            // Forward action placeholder
        }
        actions.append(forward)

        // Quick reactions submenu
        let quickEmojis = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F64F}"]
        let reactionActions = quickEmojis.map { emoji in
            UIAction(title: emoji) { [weak self] _ in
                self?.onReactToMessage?(emoji, message.id)
            }
        }
        let reactMenu = UIMenu(
            title: "React",
            image: UIImage(systemName: "face.smiling"),
            children: reactionActions
        )
        actions.append(reactMenu)

        // Delete (outgoing only)
        if message.isOutgoing {
            let delete = UIAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                // Delete action — wired up by ChatDetailView integration
            }
            actions.append(delete)
        }

        return UIMenu(children: actions)
    }

    // MARK: - Swipe-to-Reply Gesture

    private func attachSwipeGesture(to cell: UICollectionViewCell, message: Message) {
        // Remove existing swipe gestures to avoid duplicates on cell reuse
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

// MARK: - ReactionPillsRow (lightweight wrapper for UIHostingConfiguration)

/// Thin wrapper so cell registration can embed reaction pills without importing
/// the private `ReactionPillsView` from ChatDetailView.
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

// MARK: - SwipeToReplyGesture

/// Custom UIPanGestureRecognizer that handles horizontal swipe-to-reply with a
/// reply arrow indicator and spring-back animation.
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
                // Left swipe for outgoing
                swipeDistance = min(0, translation.x) * 0.5
            } else {
                // Right swipe for incoming
                swipeDistance = max(0, translation.x) * 0.5
            }

            cell.transform = CGAffineTransform(translationX: swipeDistance, y: 0)
            updateReplyIndicator(offset: swipeDistance)

            let absDistance = abs(swipeDistance)
            if absDistance >= threshold / 2 && !didTrigger {
                didTrigger = true
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
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
