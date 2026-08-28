import AVKit
import SwiftUI
import SanchrShared

/// Pre-send review for a multi-photo selection: one large preview, a filmstrip
/// to move between photos and drop any of them, a per-photo caption, and an
/// edit pass on the photo currently on screen.
///
/// Sending several photos previously had no review stop at all — the batch went
/// straight out, because the per-photo editor could not be chained without
/// clobbering itself.
struct MediaBatchReviewView: View {
    @State var model: MediaBatchReviewModel
    let onSend: ([BatchMediaItem]) -> Void
    let onCancel: () -> Void

    @FocusState private var captionFocused: Bool
    @State private var editing: EditingImage?

    /// Full-size image for the photo on screen, decoded on demand so the batch
    /// never holds more than one large bitmap.
    @State private var preview: UIImage?
    /// Player for the current item when it is a video. Torn down on every
    /// change so a clip cannot keep playing behind another item.
    @State private var player: AVPlayer?

    private struct EditingImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        ZStack {
            // Backdrop spans the whole screen and stays put — including when
            // the keyboard appears, which is what `.keyboard` in the region
            // list buys us.
            Color.black.ignoresSafeArea()

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Tapping the image dismisses the keyboard. Present only while it
            // is up, so it never competes with the zoom gestures underneath.
            if captionFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { captionFocused = false }
            }
        }
        // safeAreaInset rather than a VStack inside the ZStack: the ZStack
        // sizes to its full-bleed children, so keyboard avoidance never
        // reached the caption row and it stayed pinned under the keyboard.
        // An inset participates in avoidance and in the safe area both.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                cancelButton
                Spacer()
                editButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // The filmstrip is noise while typing, and hiding it gives the
                // caption room on a short screen.
                if !captionFocused { filmstrip }
                bottomBar
            }
            .animation(.easeInOut(duration: 0.2), value: captionFocused)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { captionFocused = false }
            }
        }
        .statusBarHidden(true)
        .task(id: model.current?.id) { await loadPreview() }
        .onChange(of: model.isEmpty) { _, empty in
            // The last photo was removed — there is nothing left to review.
            if empty { onCancel() }
        }
        .fullScreenCover(item: $editing) { pending in
            ImageEditorView(sourceImage: pending.image) { edited in
                editing = nil
                applyEdit(edited)
            } onCancel: {
                editing = nil
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var previewContent: some View {
        if let player {
            VideoPlayer(player: player)
        } else if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .zoomable()
        } else {
            ProgressView().tint(.white)
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        thumbnail(item: item, index: index)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 68)
            .onChange(of: model.currentIndex) { _, _ in
                guard let id = model.current?.id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func thumbnail(item: BatchMediaItem, index: Int) -> some View {
        let isCurrent = index == model.currentIndex
        return Group {
            if let image = item.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.15)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isCurrent ? Color.white : .clear, lineWidth: 2)
        }
        // Videos are marked so the strip is readable at a glance — otherwise a
        // clip is indistinguishable from a still at 56pt.
        .overlay(alignment: .bottomTrailing) {
            if case .video(let duration) = item.kind {
                HStack(spacing: 2) {
                    Image(systemName: "play.fill").font(.system(size: 7, weight: .bold))
                    if let duration, let text = Self.durationText(duration) {
                        Text(text).font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(3)
            }
        }
        // A captioned item is marked, so captions written earlier in the batch
        // are not forgotten once the filmstrip scrolls away from them.
        .overlay(alignment: .bottomLeading) {
            if !item.caption.isEmpty {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(3)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                model.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .padding(2)
            .accessibilityLabel("Remove item \(index + 1)")
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(index) }
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField(
                "Add a caption…",
                text: Binding(get: { model.currentCaption }, set: { model.currentCaption = $0 }),
                axis: .vertical
            )
            .lineLimit(1...4)
            .foregroundColor(.white)
            .tint(.white)
            .focused($captionFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 20))

            Button {
                onSend(model.items)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                    Text("\(model.items.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(.white, in: Circle())
                        .offset(x: 4, y: -3)
                }
            }
            .accessibilityLabel("Send \(model.items.count) items")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
        }
        .accessibilityLabel("Cancel")
    }

    private var editButton: some View {
        Button {
            guard let preview, model.canEditCurrent else { return }
            editing = EditingImage(image: preview)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
        }
        // Hidden rather than merely disabled for video: the editor makes a
        // still, so there is nothing it could usefully do to a clip.
        .opacity(model.canEditCurrent ? 1 : 0)
        .disabled(preview == nil || !model.canEditCurrent)
        .accessibilityLabel("Edit photo")
    }

    // MARK: - Actions

    private func loadPreview() async {
        // Always tear the old player down first, or a clip keeps playing behind
        // whatever the user moved to.
        player?.pause()
        player = nil

        guard let item = model.current else {
            preview = nil
            return
        }

        if item.kind.isVideo {
            preview = nil
            let p = AVPlayer(url: item.fileURL)
            player = p
            p.play()
            return
        }

        let url = item.fileURL
        preview = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
            return UIImage(data: data)
        }.value
    }

    /// Writes the edited image to a fresh temp file and swaps it in. The caption
    /// and position are untouched — editing a photo must not lose what was
    /// typed against it.
    private func applyEdit(_ image: UIImage) {
        guard let jpeg = image.jpegData(compressionQuality: 0.92) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        guard (try? jpeg.write(to: url)) != nil else {
            SanchrLogger.media.error("Could not stage edited photo for batch send")
            return
        }
        model.applyEdit(
            fileURL: url,
            sizeBytes: Int64(jpeg.count),
            thumbnail: BatchThumbnail.make(from: image)
        )
        preview = image
    }
}

extension MediaBatchReviewView {
    /// m:ss for the filmstrip badge; nil for a duration that is not usable.
    static func durationText(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Small square used in the filmstrip.
enum BatchThumbnail {
    static let side: CGFloat = 160

    static func make(from image: UIImage) -> UIImage? {
        let target = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            // Aspect-fill into the square so the strip reads as a tidy row.
            let scale = max(target.width / image.size.width, target.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(
                in: CGRect(
                    x: (target.width - size.width) / 2,
                    y: (target.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
            )
        }
    }
}
