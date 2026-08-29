import SwiftUI

struct GalleryPageView: View {
    let item: GalleryItem
    let isActive: Bool
    @ObservedObject var loader: GalleryPageLoader
    var onZoomChange: ((Bool) -> Void)?

    var body: some View {
        let state = loader.state(for: item)

        Group {
            switch item.kind {
            case .image:
                imageContent(state: state)
            case .video:
                videoContent(state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func imageContent(state: GalleryPageLoader.PageState) -> some View {
        if let image = state.image {
            GalleryImageView(image: image, onZoomChange: onZoomChange)
                .ignoresSafeArea()
        } else if let error = state.error {
            retryView(error: error)
        } else {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func videoContent(state: GalleryPageLoader.PageState) -> some View {
        if let url = state.url {
            GalleryVideoView(
                url: url,
                isActive: .constant(isActive)
            )
            .ignoresSafeArea()
        } else if let error = state.error {
            retryView(error: error)
        } else {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func retryView(error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.yellow)

            Text(error)
                .font(.footnote)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if #available(iOS 26.0, *) {
                Button("Retry") {
                    loader.retry(item)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button("Retry") {
                    loader.retry(item)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
