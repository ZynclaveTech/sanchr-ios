import SwiftUI
import UIKit
import SanchrShared

/// Fullscreen image + video gallery. A `TabView` paginated in page-style
/// gives us free horizontal swipe between media; per-page content is an
/// image (zoom + pan via `GalleryImageView`) or a video (`GalleryVideoView`
/// wrapping `AVPlayerViewController`).
///
/// Dismissal: tap the X, swipe down (`DragGesture` on the current page
/// that translates + fades the backdrop, commits past a velocity/distance
/// threshold), or drag-down past 120pt. Chrome (header) fades in/out on
/// single tap.
struct MediaGalleryView: View {
    let presentation: MediaGalleryCoordinator.GalleryPresentation
    let resolver: ChatMediaResolving
    let onDismiss: () -> Void

    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0
    @State private var backgroundOpacity: Double = 1
    @State private var resolvedURLs: [String: URL] = [:]
    @State private var loadError: [String: String] = [:]
    @State private var chromeVisible: Bool = true

    init(
        presentation: MediaGalleryCoordinator.GalleryPresentation,
        resolver: ChatMediaResolving,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.resolver = resolver
        self.onDismiss = onDismiss
        self._currentIndex = State(initialValue: presentation.initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(presentation.items.enumerated()), id: \.offset) { index, item in
                    pageContent(item: item, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .highPriorityGesture(dismissDrag)

            if chromeVisible {
                chromeOverlay
            }
        }
        .statusBarHidden(true)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
        .task(id: currentIndex) {
            await resolveIfNeeded(at: currentIndex)
            await resolveIfNeeded(at: currentIndex + 1)
            await resolveIfNeeded(at: currentIndex - 1)
        }
    }

    @ViewBuilder
    private func pageContent(item: GalleryItem, index: Int) -> some View {
        switch item.kind {
        case .image:
            GalleryImageView(image: resolvedImage(for: item))
                .ignoresSafeArea()
        case .video:
            if let url = resolvedURLs[item.id] {
                GalleryVideoView(
                    url: url,
                    isActive: .constant(index == currentIndex)
                )
                .ignoresSafeArea()
            } else if let error = loadError[item.id] {
                retryView(error: error, messageId: item.id)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var chromeOverlay: some View {
        VStack {
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Circle())
                }
                .padding(.leading, 16)

                Spacer()

                if presentation.items.indices.contains(currentIndex) {
                    Text(Self.titleText(for: presentation.items[currentIndex].message))
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()

                // Overflow slot — populated in Phase 3 (Save / Share / Copy).
                Color.clear.frame(width: 36, height: 36).padding(.trailing, 16)
            }
            .padding(.top, 50)

            Spacer()
        }
    }

    @ViewBuilder
    private func retryView(error: String, messageId: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.yellow)
            Text(error)
                .font(.footnote)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                loadError[messageId] = nil
                Task { await resolveIfNeeded(at: currentIndex) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Dismiss drag

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragOffset = value.translation.height
                backgroundOpacity = max(0, 1 - Double(value.translation.height / 400))
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 240 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = 1000
                        backgroundOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                    }
                } else {
                    withAnimation(.spring()) {
                        dragOffset = 0
                        backgroundOpacity = 1
                    }
                }
            }
    }

    // MARK: - Resolution

    @MainActor
    private func resolveIfNeeded(at index: Int) async {
        guard presentation.items.indices.contains(index) else { return }
        let item = presentation.items[index]
        guard resolvedURLs[item.id] == nil, loadError[item.id] == nil else { return }
        guard let attachment = Self.attachment(for: item.message) else { return }
        do {
            let url = try await resolver.decryptedURL(
                forMessageId: item.id,
                attachment: attachment
            )
            resolvedURLs[item.id] = url
        } catch {
            loadError[item.id] = error.localizedDescription
        }
    }

    private func resolvedImage(for item: GalleryItem) -> UIImage? {
        guard let url = resolvedURLs[item.id] else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func attachment(for message: Message) -> Message.MediaAttachment? {
        switch message.content {
        case .image(let a), .video(let a): return a
        default: return nil
        }
    }

    private static func titleText(for message: Message) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: message.timestamp, relativeTo: Date())
    }
}
