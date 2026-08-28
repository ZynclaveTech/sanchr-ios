import AVFoundation
import SwiftUI
import SanchrShared

struct SharedContentView: View {
    let conversation: Conversation

    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SharedContentViewModel()
    @State private var galleryPresentation: SharedContentGalleryPresentation?
    @State private var documentURL: SharedContentDocURL?

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            contentBody
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Shared")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadInitial(
                conversationId: conversation.id,
                localDatabase: container.localDatabase
            )
        }
        .fullScreenCover(item: $galleryPresentation) { presentation in
            MediaGalleryView(
                presentation: MediaGalleryCoordinator.GalleryPresentation(
                    items: presentation.items,
                    initialIndex: presentation.initialIndex
                ),
                resolver: container.chatMediaResolver,
                onDismiss: { galleryPresentation = nil }
            )
        }
        .fullScreenCover(item: $documentURL) { wrapped in
            DocumentPreviewView(
                fileURL: wrapped.url,
                onDismiss: { documentURL = nil }
            )
        }
    }

    @ViewBuilder
    private var tabPicker: some View {
        Picker("Shared content tab", selection: $viewModel.currentTab) {
            ForEach(SharedContentViewModel.Tab.allCases) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch viewModel.currentTab {
        case .media: mediaTab
        case .links: linksTab
        case .docs:  docsTab
        }
    }

    @ViewBuilder
    private var mediaTab: some View {
        if viewModel.media.isEmpty && !viewModel.isLoading {
            emptyState(icon: "photo.on.rectangle.angled", text: "No media in this chat")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                    spacing: 2
                ) {
                    ForEach(viewModel.media, id: \.id) { message in
                        SharedContentMediaCell(
                            message: message,
                            resolver: container.chatMediaResolver
                        )
                        .onTapGesture {
                            openGallery(for: message)
                        }
                    }
                }
                .padding(.horizontal, 2)

                loadMoreFooter
            }
        }
    }

    @ViewBuilder
    private var linksTab: some View {
        if viewModel.links.isEmpty && !viewModel.isLoading {
            emptyState(icon: "link", text: "No links shared")
        } else {
            List {
                ForEach(viewModel.links) { link in
                    Button {
                        UIApplication.shared.open(link.url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .font(.system(size: 18))
                                .frame(width: 28, height: 28)
                                .foregroundColor(SanchrColors.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.displayDomain)
                                    .font(SanchrTypography.messageBubbleText)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .lineLimit(1)
                                Text(link.url.absoluteString)
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(link.date.formatted(date: .abbreviated, time: .omitted))
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(SanchrExportColors.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if viewModel.hasMore {
                    loadMoreRow
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var docsTab: some View {
        if viewModel.docs.isEmpty && !viewModel.isLoading {
            emptyState(icon: "doc.fill", text: "No documents shared")
        } else {
            List {
                ForEach(viewModel.docs, id: \.id) { message in
                    if case .document(let media) = message.content,
                       let attachment = media.first {
                        Button {
                            Task { await openDocument(message: message, attachment: attachment) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: Self.iconName(for: attachment.mimeType))
                                    .font(.system(size: 22))
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(SanchrColors.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.filename ?? attachment.url.lastPathComponent)
                                        .font(SanchrTypography.messageBubbleText)
                                        .foregroundColor(SanchrExportColors.textPrimary)
                                        .lineLimit(1)
                                    Text(Self.formatBytes(attachment.sizeBytes))
                                        .font(SanchrTypography.captionSmall)
                                        .foregroundColor(SanchrExportColors.textSecondary)
                                }
                                Spacer()
                                Text(message.timestamp.formatted(date: .abbreviated, time: .omitted))
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if viewModel.hasMore {
                    loadMoreRow
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if viewModel.hasMore {
            Button {
                Task {
                    await viewModel.loadMore(
                        conversationId: conversation.id,
                        localDatabase: container.localDatabase
                    )
                }
            } label: {
                Text(viewModel.isLoading ? "Loading…" : "Load More")
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrColors.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .disabled(viewModel.isLoading)
        }
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        Button {
            Task {
                await viewModel.loadMore(
                    conversationId: conversation.id,
                    localDatabase: container.localDatabase
                )
            }
        } label: {
            HStack {
                Spacer()
                Text(viewModel.isLoading ? "Loading…" : "Load More")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrColors.primary)
                Spacer()
            }
        }
        .disabled(viewModel.isLoading)
    }

    @ViewBuilder
    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(SanchrExportColors.textTertiary)
            Text(text)
                .font(SanchrTypography.messageBubbleText)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Actions

    private func openGallery(for tappedMessage: Message) {
        let galleryItems = viewModel.media
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { msg -> GalleryItem? in
                switch msg.content {
                case .image: return GalleryItem(id: msg.id, kind: .image, message: msg)
                case .video: return GalleryItem(id: msg.id, kind: .video, message: msg)
                default: return nil
                }
            }
        let initialIndex = galleryItems.firstIndex(where: { $0.id == tappedMessage.id }) ?? 0
        galleryPresentation = SharedContentGalleryPresentation(
            items: galleryItems,
            initialIndex: initialIndex
        )
    }

    private func openDocument(message: Message, attachment: Message.MediaAttachment) async {
        do {
            let url = try await container.chatMediaResolver.decryptedURLWithDisplayName(
                forMessageId: message.id,
                attachment: attachment
            )
            documentURL = SharedContentDocURL(url: url)
        } catch {
            // Silent: could surface an alert here in a future iteration.
        }
    }

    // MARK: - Formatting helpers

    private static func iconName(for mime: String) -> String {
        if mime.contains("pdf") { return "doc.text.fill" }
        if mime.contains("word") || mime.contains("officedocument.wordprocessingml") { return "doc.fill" }
        if mime.contains("sheet") || mime.contains("excel") { return "tablecells.fill" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.stack.fill" }
        return "doc"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct SharedContentGalleryPresentation: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let initialIndex: Int
}

private struct SharedContentDocURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SharedContentMediaCell: View {
    let message: Message
    let resolver: ChatMediaResolving

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(SanchrExportColors.surfaceSoft)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 3)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: message.id) {
            await loadThumbnail()
        }
    }

    private var isVideo: Bool {
        if case .video = message.content { return true }
        return false
    }

    private func loadThumbnail() async {
        guard let attachment = Self.attachment(for: message) else { return }
        do {
            let url = try await resolver.decryptedURL(
                forMessageId: message.id,
                attachment: attachment
            )
            let loaded: UIImage?
            if isVideo {
                loaded = await MediaThumbnailGenerator.posterFrame(forVideoAt: url)
            } else {
                loaded = UIImage(contentsOfFile: url.path)
            }
            if let loaded {
                await MainActor.run { self.image = loaded }
            }
        } catch {
            // Silent: leave the placeholder rectangle.
        }
    }

    private static func attachment(for message: Message) -> Message.MediaAttachment? {
        switch message.content {
        case .image(let media), .video(let media): return media.first
        default: return nil
        }
    }
}
