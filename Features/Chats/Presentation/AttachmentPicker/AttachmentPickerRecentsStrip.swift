// AttachmentPickerRecentsStrip.swift
import UIKit
import Combine
import SanchrShared

@MainActor
protocol AttachmentPickerRecentsStripDelegate: AnyObject {
    func recentsStrip(_ strip: AttachmentPickerRecentsStrip, didTapPhotoAt id: String)
    func recentsStrip(_ strip: AttachmentPickerRecentsStrip, didLongPressPhotoAt id: String)
}

@MainActor
final class AttachmentPickerRecentsStrip: UIView {

    weak var delegate: AttachmentPickerRecentsStripDelegate?

    private let layout: UICollectionViewFlowLayout = {
        let l = UICollectionViewFlowLayout()
        l.scrollDirection = .horizontal
        l.itemSize = CGSize(width: 112, height: 112)
        l.minimumInteritemSpacing = 6
        l.minimumLineSpacing = 6
        l.sectionInset = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return l
    }()

    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.showsHorizontalScrollIndicator = false
        cv.dataSource = self
        cv.delegate = self
        cv.register(RecentPhotoCell.self, forCellWithReuseIdentifier: "photo")
        cv.accessibilityIdentifier = "attachmentPicker.recentsStrip"
        return cv
    }()

    private var recents: [RecentPhoto] = []
    /// Ordered, so a cell can show *where* in the batch it sits.
    private var selectedIDs: [String] = []
    private var isMultiSelecting = false
    private let photosSource: PhotosLibrarySource

    init(photosSource: PhotosLibrarySource) {
        self.photosSource = photosSource
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        lp.minimumPressDuration = 0.4
        collectionView.addGestureRecognizer(lp)
    }

    func update(recents: [RecentPhoto], selected: [String], multiSelecting: Bool) {
        self.recents = recents
        self.selectedIDs = selected
        self.isMultiSelecting = multiSelecting
        collectionView.reloadData()
    }

    @objc private func onLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let point = gr.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: point) else { return }
        let photo = recents[ip.item]
        delegate?.recentsStrip(self, didLongPressPhotoAt: photo.id)
    }
}

extension AttachmentPickerRecentsStrip: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        recents.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let photo = recents[ip.item]

        // Safe cast to RecentPhotoCell — if wrong type, create a blank cell
        guard let c = cv.dequeueReusableCell(withReuseIdentifier: "photo", for: ip) as? RecentPhotoCell else {
            SanchrLogger.ui.error("AttachmentPickerRecentsStrip: Cell is not RecentPhotoCell (got \(type(of: cv.dequeueReusableCell(withReuseIdentifier: "photo", for: ip))))")
            return cv.dequeueReusableCell(withReuseIdentifier: "photo", for: ip)
        }

        c.isAccessibilityElement = true
        c.accessibilityLabel = "Recent photo"
        c.accessibilityTraits = .button
        c.accessibilityIdentifier = "attachmentPicker.recentPhoto.\(ip.item)"
        let src = photosSource
        c.configure(photo: photo,
                    selectionIndex: selectedIDs.firstIndex(of: photo.id),
                    multiSelecting: isMultiSelecting,
                    thumbnailLoader: { size in
                        await src.loadThumbnail(assetID: photo.id, targetSize: size)
                    })
        return c
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        delegate?.recentsStrip(self, didTapPhotoAt: recents[ip.item].id)
    }
}

// MARK: Cells

@MainActor
final class RecentPhotoCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let selectionBadge = UIImageView()
    private let selectionBadgeLabel = UILabel()
    private let videoGradientLayer = CAGradientLayer()
    private let videoPlayIcon = UIImageView()
    private let videoDurationLabel = UILabel()
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        contentView.addSubview(imageView)
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Video overlay: subtle bottom gradient so the play icon + duration
        // stay legible regardless of the underlying thumbnail brightness.
        videoGradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor
        ]
        videoGradientLayer.locations = [0.4, 1.0]
        videoGradientLayer.isHidden = true
        contentView.layer.addSublayer(videoGradientLayer)

        let playCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        videoPlayIcon.image = UIImage(systemName: "play.fill", withConfiguration: playCfg)
        videoPlayIcon.tintColor = .white
        videoPlayIcon.contentMode = .center
        videoPlayIcon.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        videoPlayIcon.layer.cornerRadius = 12
        videoPlayIcon.layer.masksToBounds = true
        videoPlayIcon.isHidden = true
        contentView.addSubview(videoPlayIcon)

        videoDurationLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        videoDurationLabel.textColor = .white
        videoDurationLabel.shadowColor = UIColor.black.withAlphaComponent(0.4)
        videoDurationLabel.shadowOffset = CGSize(width: 0, height: 0.5)
        videoDurationLabel.isHidden = true
        contentView.addSubview(videoDurationLabel)

        selectionBadge.frame = CGRect(x: 6, y: 6, width: 22, height: 22)
        selectionBadge.backgroundColor = .systemPurple
        selectionBadge.tintColor = .white
        selectionBadge.contentMode = .center
        selectionBadge.layer.cornerRadius = 11
        selectionBadge.layer.masksToBounds = true
        selectionBadge.isHidden = true
        contentView.addSubview(selectionBadge)

        // The number lives in a label rather than a checkmark glyph, because
        // the send order is the tap order and the user has to be able to see it.
        selectionBadgeLabel.font = .systemFont(ofSize: 12, weight: .bold)
        selectionBadgeLabel.textColor = .white
        selectionBadgeLabel.textAlignment = .center
        selectionBadgeLabel.frame = selectionBadge.bounds
        selectionBadgeLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        selectionBadgeLabel.isHidden = true
        selectionBadge.addSubview(selectionBadgeLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Gradient covers the bottom ~40% of the cell.
        let h = contentView.bounds.height
        videoGradientLayer.frame = CGRect(
            x: 0, y: h * 0.55,
            width: contentView.bounds.width, height: h * 0.45
        )
        // Play badge pinned bottom-right with an 8pt inset.
        let playSize: CGFloat = 24
        videoPlayIcon.frame = CGRect(
            x: contentView.bounds.width - playSize - 8,
            y: contentView.bounds.height - playSize - 8,
            width: playSize, height: playSize
        )
        // Duration sits to the left of the play badge on the same row.
        videoDurationLabel.sizeToFit()
        let durW = max(videoDurationLabel.bounds.width, 28)
        videoDurationLabel.frame = CGRect(
            x: videoPlayIcon.frame.minX - durW - 6,
            y: contentView.bounds.height - 8 - videoDurationLabel.bounds.height,
            width: durW,
            height: videoDurationLabel.bounds.height
        )
    }

    func configure(photo: RecentPhoto, selectionIndex: Int?, multiSelecting: Bool,
                   thumbnailLoader: @escaping @MainActor @Sendable (CGSize) async -> UIImage?) {
        selectionBadge.isHidden = !multiSelecting
        // Numbered rather than a bare tick: the send order is the tap order, so
        // the badge has to show it or the user cannot tell what they will get.
        let isSelected = selectionIndex != nil
        selectionBadgeLabel.text = selectionIndex.map { String($0 + 1) } ?? ""
        selectionBadgeLabel.isHidden = !isSelected
        selectionBadge.backgroundColor = isSelected ? .systemPurple : UIColor.black.withAlphaComponent(0.3)

        let isVideo = photo.kind == .video
        videoGradientLayer.isHidden = !isVideo
        videoPlayIcon.isHidden = !isVideo
        videoDurationLabel.isHidden = !isVideo
        if isVideo {
            videoDurationLabel.text = Self.formatDuration(photo.durationSeconds ?? 0)
            setNeedsLayout()
        }

        imageView.image = nil
        loadTask?.cancel()
        let size = bounds.size
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.imageView.image = await thumbnailLoader(size)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        videoGradientLayer.isHidden = true
        videoPlayIcon.isHidden = true
        videoDurationLabel.isHidden = true
        videoDurationLabel.text = nil
    }

    /// Mirrors the standard media-duration formatting used elsewhere in the
    /// app: `m:ss` for anything under an hour, `h:mm:ss` otherwise. A nil or
    /// zero duration renders as a dash so unexpected photo-typed rows don't
    /// look broken if they slip through.
    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
