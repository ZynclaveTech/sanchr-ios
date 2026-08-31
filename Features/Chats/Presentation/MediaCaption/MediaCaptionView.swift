// Features/Chats/Presentation/MediaCaption/MediaCaptionView.swift
import AVKit
import SwiftUI

/// Pre-send media preview screen. Shows the image or video full-screen with a
/// caption text field at the bottom. Tapping Send calls `onSend` with the
/// trimmed caption (or nil if left empty). Tapping the ✕ calls `onCancel`.
struct MediaCaptionView: View {

    // MARK: - Types

    /// The media to preview. Image data is held in memory (photos are typically
    /// < 5 MB at JPEG quality). Video is referenced by file URL to avoid
    /// duplicating large buffers.
    enum Preview: Sendable {
        case image(Data)
        case video(URL)
    }

    // MARK: - Inputs

    let preview: Preview
    /// Called when the user taps Send. `caption` is nil if the field was left empty.
    let onSend: (_ caption: String?) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var caption: String = ""
    @FocusState private var captionFocused: Bool
    @State private var player: AVPlayer? = nil

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            // Dim the bottom third so text is readable over media
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Tapping the media dismisses the keyboard, which otherwise had no
            // way out on this screen: it opens focused and there is no Return
            // key on a multi-line field.
            if captionFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { captionFocused = false }
            }
        }
        // An inset rather than a ZStack child: the ZStack sizes to its
        // full-bleed children, so keyboard avoidance never reached the caption
        // row and it stayed pinned behind the keyboard.
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { captionFocused = false }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack { cancelButton; Spacer() }
        }
        // This view must always be presented via .fullScreenCover to own the status bar.
        .statusBarHidden(true)
        .onAppear {
            if case .video(let url) = preview {
                player = AVPlayer(url: url)
                player?.play()
                Task { videoAspectRatio = await MediaAspectFill.aspectRatio(ofVideoAt: url) }
            }
            captionFocused = true
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var previewContent: some View {
        switch preview {
        case .image(let data):
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .zoomable()
            } else {
                // Fallback: corrupted/unsupported image data
                Image(systemName: "photo")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.4))
            }

        case .video:
            if let player {
                // Gravity, not frames. `VideoPlayer` letterboxes inside
                // whatever frame it is handed, so sizing the SwiftUI view had
                // no effect on where the picture's edges landed.
                GeometryReader { proxy in
                    VideoPreviewLayer(
                        player: player,
                        fills: MediaAspectFill.presentationRatio(
                            content: videoAspectRatio,
                            container: proxy.size
                        ).contentMode == .fill
                    )
                }
            }
        }
    }

    /// The clip's width ÷ height, once its track has been read. Nil until then,
    /// which the ratio treats as "fit" — better a moment of letterbox than a
    /// crop guessed from nothing.
    @State private var videoAspectRatio: CGFloat?

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Add a caption…", text: $caption, axis: .vertical)
                .lineLimit(1...4)
                .foregroundColor(.white)
                .tint(.white)
                .focused($captionFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 20))

            Button(action: handleSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 12)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 8)
        .accessibilityLabel("Cancel")
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        onSend(trimmed.isEmpty ? nil : trimmed)
    }
}
