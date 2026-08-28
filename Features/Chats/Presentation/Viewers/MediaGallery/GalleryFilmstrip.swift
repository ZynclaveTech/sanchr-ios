import SwiftUI
import SanchrShared

/// Thumbnail strip along the bottom of the media viewer.
///
/// Shows every page in the gallery so an album — or a whole conversation's
/// media — can be jumped through directly rather than swiped one at a time.
///
/// Thumbnails come from `GalleryPageLoader`'s existing state, so a strip entry
/// costs nothing beyond what the pager already decoded. Pages outside the
/// loader's window have not been fetched yet and show a placeholder rather than
/// triggering their own download, which would defeat the windowing the loader
/// does deliberately.
struct GalleryFilmstrip: View {
    let items: [GalleryItem]
    @Binding var currentIndex: Int
    @ObservedObject var loader: GalleryPageLoader

    private let side: CGFloat = 52

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        thumbnail(for: item, at: index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: side + 12)
            .onChange(of: currentIndex) { _, index in
                // Keep the strip following the pager, so the highlighted entry
                // is always the one on screen.
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
        }
        .background(.black.opacity(0.45))
    }

    @ViewBuilder
    private func thumbnail(for item: GalleryItem, at index: Int) -> some View {
        let isCurrent = index == currentIndex
        Group {
            if let image = loader.states[item.id]?.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // Not yet loaded, or outside the loader's window.
                Color.white.opacity(0.12)
                    .overlay {
                        Image(systemName: item.kind == .video ? "play.fill" : "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isCurrent ? Color.white : .clear, lineWidth: 2)
        }
        // Video is otherwise indistinguishable from a still at this size.
        .overlay(alignment: .bottomTrailing) {
            if item.kind == .video, loader.states[item.id]?.image != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(2)
            }
        }
        .opacity(isCurrent ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { currentIndex = index }
        }
        .accessibilityLabel("Item \(index + 1) of \(items.count)")
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }
}
