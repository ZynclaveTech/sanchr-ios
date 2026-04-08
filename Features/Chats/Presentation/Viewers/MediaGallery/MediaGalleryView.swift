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
    let onDismiss: () -> Void

    @Environment(DependencyContainer.self) private var container
    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0
    @State private var backgroundOpacity: Double = 1
    @State private var chromeVisible: Bool = true
    @State private var toast: String?
    @State private var saveError: String?
    @State private var shareURL: GalleryIdentifiedURL?
    @State private var openedViewOnceItems: Set<String> = []
    @State private var screenshotToast: String?
    @StateObject private var pageLoader: GalleryPageLoader

    init(
        presentation: MediaGalleryCoordinator.GalleryPresentation,
        resolver: ChatMediaResolving,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.onDismiss = onDismiss
        self._currentIndex = State(initialValue: presentation.initialIndex)
        self._pageLoader = StateObject(wrappedValue: GalleryPageLoader(resolver: resolver))
    }

    /// True if any item in the current presentation is view-once.
    /// We blanket-protect the gallery rather than toggling per-page
    /// because page transitions race the screenshot block.
    private var anyViewOnceVisible: Bool {
        presentation.items.contains { item in
            switch item.message.content {
            case .image(let a), .video(let a):
                return a.isViewOnce == true
            default:
                return false
            }
        }
    }

    /// Whether the per-chat screenshot-protection toggle is on for
    /// the conversation this gallery is showing.
    private var perChatScreenshotProtection: Bool {
        guard let cid = presentation.items.first?.message.conversationId else { return false }
        return container.chatVaultPolicy.effectivePolicy(for: cid).screenshotProtection
    }

    private func captureViewOnceIfNeeded(at index: Int) {
        guard presentation.items.indices.contains(index) else { return }
        let item = presentation.items[index]
        let isViewOnce: Bool
        switch item.message.content {
        case .image(let a), .video(let a):
            isViewOnce = a.isViewOnce == true
        default:
            isViewOnce = false
        }
        if isViewOnce { openedViewOnceItems.insert(item.id) }
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(presentation.items.enumerated()), id: \.offset) { index, item in
                    GalleryPageView(
                        item: item,
                        isActive: index == currentIndex,
                        loader: pageLoader
                    )
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
        .modifier(ScreenshotProtectionModifier(isActive: anyViewOnceVisible || perChatScreenshotProtection))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
        .task(id: currentIndex) {
            pageLoader.updateWindow(
                items: presentation.items,
                centeredAt: currentIndex
            )
            captureViewOnceIfNeeded(at: currentIndex)
        }
        .onAppear {
            captureViewOnceIfNeeded(at: currentIndex)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification
        )) { _ in
            guard anyViewOnceVisible,
                  let cid = presentation.items.first?.message.conversationId else { return }
            screenshotToast = "Sender notified"
            Task {
                try? await container.messageRepository.sendSystemEvent(
                    .screenshotDetected,
                    conversationId: cid
                )
            }
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
                SanchrToastBadge(text: toast)
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
        .overlay(alignment: .top) {
            if let screenshotToast {
                Text(screenshotToast)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 60)
                    .task(id: screenshotToast) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { self.screenshotToast = nil }
                    }
            }
        }
        .onDisappear {
            pageLoader.cancelAll()
            // Fire delete-after-view for every view-once item the user
            // actually paged onto during this gallery session.
            let toDelete = openedViewOnceItems
            openedViewOnceItems.removeAll()
            for messageId in toDelete {
                Task { [container] in
                    try? await container.messageRepository.deleteViewOnceMessage(
                        messageId: messageId
                    )
                }
            }
        }
    }

    // MARK: - Overflow actions

    private func currentItem() -> GalleryItem? {
        guard presentation.items.indices.contains(currentIndex) else { return nil }
        return presentation.items[currentIndex]
    }

    private func saveCurrentToPhotos() async {
        guard let item = currentItem(), let url = pageLoader.url(for: item) else {
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
        guard let item = currentItem(), let url = pageLoader.url(for: item) else { return }
        shareURL = GalleryIdentifiedURL(url: url)
    }

    private func copyCurrent() {
        guard let item = currentItem() else { return }
        let state = pageLoader.state(for: item)
        if item.kind == .image, let image = state.image {
            UIPasteboard.general.image = image
            toast = "Image copied"
        } else if let url = state.url {
            UIPasteboard.general.url = url
            toast = "Link copied"
        }
    }

    @ViewBuilder
    private var chromeOverlay: some View {
        VStack {
            SanchrGlassCluster(spacing: 20) {
                HStack {
                    SanchrIconButton(
                        systemName: "xmark",
                        foreground: .white,
                        background: Color.white.opacity(0.2),
                        size: 36,
                        glassTint: Color.white.opacity(0.12)
                    ) {
                        onDismiss()
                    }
                    .padding(.leading, 16)

                    Spacer()

                    if presentation.items.indices.contains(currentIndex) {
                        chromeTitlePill(
                            text: Self.titleText(
                                for: presentation.items[currentIndex].message
                            )
                        )
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
                        galleryChromeIcon(systemName: "ellipsis")
                    }
                    .padding(.trailing, 16)
                }
            }
            .padding(.top, 50)

            Spacer()
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

    private static func titleText(for message: Message) -> String {
        relativeFormatter.localizedString(for: message.timestamp, relativeTo: Date())
    }

    private func galleryChromeIcon(systemName: String) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .sanchrGlass(
                        role: .toolbarButton,
                        interactive: true,
                        tint: Color.white.opacity(0.12)
                    )
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }
        }
    }

    private func chromeTitlePill(text: String) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                Text(text)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .sanchrGlass(
                        role: .toast,
                        tint: Color.white.opacity(0.08)
                    )
            } else {
                Text(text)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Capsule())
            }
        }
    }
}

private extension MediaGalleryView {
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
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
