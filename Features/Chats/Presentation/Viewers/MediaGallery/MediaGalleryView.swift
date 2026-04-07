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
    @State private var toast: String?
    @State private var saveError: String?
    @State private var shareURL: GalleryIdentifiedURL?

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
        .alert("Couldn't save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .sheet(item: $shareURL) { wrapped in
            GalleryActivityView(items: [wrapped.url])
        }
    }

    // MARK: - Overflow actions

    private func currentItem() -> GalleryItem? {
        guard presentation.items.indices.contains(currentIndex) else { return nil }
        return presentation.items[currentIndex]
    }

    private func saveCurrentToPhotos() async {
        guard let item = currentItem(), let url = resolvedURLs[item.id] else {
            saveError = "The file isn't ready yet — try again in a moment."
            return
        }
        do {
            try await SaveToPhotos.save(
                fileURL: url,
                kind: item.kind == .video ? .video : .image
            )
            toast = item.kind == .video ? "Video saved to Photos" : "Image saved to Photos"
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func shareCurrent() {
        guard let item = currentItem(), let url = resolvedURLs[item.id] else { return }
        shareURL = GalleryIdentifiedURL(url: url)
    }

    private func copyCurrent() {
        guard let item = currentItem(), let url = resolvedURLs[item.id] else { return }
        if item.kind == .image, let image = UIImage(contentsOfFile: url.path) {
            UIPasteboard.general.image = image
            toast = "Image copied"
        } else {
            UIPasteboard.general.url = url
            toast = "Link copied"
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

                Menu {
                    Button {
                        Task { await saveCurrentToPhotos() }
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        shareCurrent()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        copyCurrent()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Circle())
                }
                .padding(.trailing, 16)
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

/// Identifiable URL wrapper so `.sheet(item:)` can drive the share sheet.
private struct GalleryIdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Thin `UIActivityViewController` wrapper used by the gallery's Share
/// overflow action.
private struct GalleryActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
