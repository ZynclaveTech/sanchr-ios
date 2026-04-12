import Kingfisher
import SwiftUI
import SanchrShared

// MARK: - StickerPickerSheet

/// Bottom-sheet picker presented from the chat composer at 280 pt height.
/// Two tabs:
///   - Stickers: built-in emoji packs rendered at 160×160 pt and sent as PNG.
///   - GIFs: Tenor trending/search — tap to send the full GIF URL downstream.
struct StickerPickerSheet: View {

    /// Called with PNG data when the user taps a sticker emoji.
    let onStickerSelected: (Data) -> Void
    /// Called with the remote Tenor GIF URL when the user taps a GIF.
    let onGIFSelected: (URL) -> Void

    @State private var selectedTab: Tab = .sticker
    @State private var selectedPackId: String = StickerStore.shared.packs.first?.id ?? ""
    @State private var gifQuery: String = ""
    @State private var gifResults: [GIFResult] = []
    @State private var isLoadingGIFs = false
    @State private var searchTask: Task<Void, Never>?

    private enum Tab { case sticker, gif }

    private let stickerColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 5)
    private let gifColumns     = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()

            switch selectedTab {
            case .sticker:
                stickerContent
            case .gif:
                gifContent
            }
        }
        .task {
            gifResults = await GIFService.shared.trending()
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Stickers", tab: .sticker)
            tabButton("GIF", tab: .gif)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func tabButton(_ title: String, tab: Tab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(selectedTab == tab ? SanchrColors.primary : SanchrExportColors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    if selectedTab == tab {
                        Rectangle()
                            .fill(SanchrColors.primary)
                            .frame(height: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sticker Content

    private var stickerContent: some View {
        VStack(spacing: 0) {
            packStrip
            Divider()
            stickerGrid
        }
    }

    private var packStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(StickerStore.shared.packs) { pack in
                    Button {
                        selectedPackId = pack.id
                    } label: {
                        Text(pack.icon)
                            .font(.system(size: 24))
                            .frame(width: 40, height: 40)
                            .background(
                                selectedPackId == pack.id
                                    ? SanchrColors.primary.opacity(0.15)
                                    : Color.clear,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var stickerGrid: some View {
        let stickers = StickerStore.shared.packs
            .first(where: { $0.id == selectedPackId })?.stickers ?? []
        return ScrollView(showsIndicators: false) {
            LazyVGrid(columns: stickerColumns, spacing: 2) {
                ForEach(stickers, id: \.self) { emoji in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let data = StickerStore.shared.renderStickerPNG(emoji)
                        onStickerSelected(data)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 36))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - GIF Content

    private var gifContent: some View {
        VStack(spacing: 0) {
            gifSearchBar
            if isLoadingGIFs {
                ProgressView()
                    .tint(SanchrColors.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if gifResults.isEmpty {
                Text("No results")
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                gifGrid
            }
        }
    }

    private var gifSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(SanchrExportColors.textTertiary)
                .font(.system(size: 14))
            TextField("Search GIFs", text: $gifQuery)
                .font(SanchrTypography.body)
                .foregroundColor(SanchrExportColors.textPrimary)
                .submitLabel(.search)
                .onSubmit { scheduleSearch() }
                .onChange(of: gifQuery) { _, _ in scheduleSearch() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SanchrExportColors.surfaceSoft, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var gifGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: gifColumns, spacing: 4) {
                ForEach(gifResults) { gif in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onGIFSelected(gif.fullURL)
                    } label: {
                        KFAnimatedImage(gif.previewURL)
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 80)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Search Debounce

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            isLoadingGIFs = true
            let results = await GIFService.shared.search(query: gifQuery)
            guard !Task.isCancelled else { return }
            gifResults = results
            isLoadingGIFs = false
        }
    }
}
