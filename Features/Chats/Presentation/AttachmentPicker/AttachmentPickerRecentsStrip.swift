// AttachmentPickerRecentsStrip.swift
import UIKit
import Combine

@MainActor
protocol AttachmentPickerRecentsStripDelegate: AnyObject {
    func recentsStrip(_ strip: AttachmentPickerRecentsStrip, didTapPhotoAt id: String)
    func recentsStrip(_ strip: AttachmentPickerRecentsStrip, didLongPressPhotoAt id: String)
    func recentsStripDidTapCameraTile(_ strip: AttachmentPickerRecentsStrip)
}

@MainActor
final class AttachmentPickerRecentsStrip: UIView {

    weak var delegate: AttachmentPickerRecentsStripDelegate?

    private let layout: UICollectionViewFlowLayout = {
        let l = UICollectionViewFlowLayout()
        l.scrollDirection = .horizontal
        l.itemSize = CGSize(width: 84, height: 84)
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
        cv.register(CameraTileCell.self, forCellWithReuseIdentifier: "camera")
        cv.accessibilityIdentifier = "attachmentPicker.recentsStrip"
        return cv
    }()

    private var recents: [RecentPhoto] = []
    private var selectedIDs: Set<String> = []
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

    func update(recents: [RecentPhoto], selected: Set<String>, multiSelecting: Bool) {
        self.recents = recents
        self.selectedIDs = selected
        self.isMultiSelecting = multiSelecting
        collectionView.reloadData()
    }

    @objc private func onLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let point = gr.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: point), ip.item > 0 else { return }
        let photo = recents[ip.item - 1]
        delegate?.recentsStrip(self, didLongPressPhotoAt: photo.id)
    }
}

extension AttachmentPickerRecentsStrip: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        1 + recents.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        if ip.item == 0 {
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "camera", for: ip)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "Camera"
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "attachmentPicker.cameraTile"
            return cell
        }
        let photo = recents[ip.item - 1]
        let c = cv.dequeueReusableCell(withReuseIdentifier: "photo", for: ip) as! RecentPhotoCell
        c.isAccessibilityElement = true
        c.accessibilityLabel = "Recent photo"
        c.accessibilityTraits = .button
        c.accessibilityIdentifier = "attachmentPicker.recentPhoto.\(ip.item - 1)"
        let src = photosSource
        c.configure(photo: photo,
                    isSelected: selectedIDs.contains(photo.id),
                    multiSelecting: isMultiSelecting,
                    thumbnailLoader: { size in
                        await src.loadThumbnail(assetID: photo.id, targetSize: size)
                    })
        return c
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        if ip.item == 0 {
            delegate?.recentsStripDidTapCameraTile(self)
        } else {
            delegate?.recentsStrip(self, didTapPhotoAt: recents[ip.item - 1].id)
        }
    }
}

// MARK: Cells

@MainActor
final class RecentPhotoCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let selectionBadge = UILabel()
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        contentView.addSubview(imageView)
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        selectionBadge.frame = CGRect(x: 4, y: 4, width: 22, height: 22)
        selectionBadge.backgroundColor = .systemPurple
        selectionBadge.textColor = .white
        selectionBadge.textAlignment = .center
        selectionBadge.layer.cornerRadius = 11
        selectionBadge.layer.masksToBounds = true
        selectionBadge.font = .systemFont(ofSize: 12, weight: .bold)
        selectionBadge.isHidden = true
        contentView.addSubview(selectionBadge)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(photo: RecentPhoto, isSelected: Bool, multiSelecting: Bool,
                   thumbnailLoader: @escaping @MainActor @Sendable (CGSize) async -> UIImage?) {
        selectionBadge.isHidden = !multiSelecting
        selectionBadge.text = isSelected ? "✓" : ""
        selectionBadge.backgroundColor = isSelected ? .systemPurple : UIColor.black.withAlphaComponent(0.3)
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
    }
}

