import SanchrShared
import SwiftUI

struct GalleryPageView: View {
    let item: GalleryItem
    let isActive: Bool
    @ObservedObject var loader: GalleryPageLoader
    var onZoomChange: ((Bool) -> Void)?
    /// Whether a call is running, so a video page never takes the audio
    /// session from one.
    var callInProgress: Bool = false

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
            retryView(error: error, isExpired: state.isExpired)
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
                isActive: .constant(isActive),
                callInProgress: callInProgress
            )
            .ignoresSafeArea()
        } else if let error = state.error {
            retryView(error: error, isExpired: state.isExpired)
        } else {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func retryView(error: String, isExpired: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: isExpired ? "clock.badge.xmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(isExpired ? .white.opacity(0.8) : .yellow)

            if isExpired {
                Text("Media expired")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(.white)
                Text("Ask them to send it again.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
            Text(error)
                .font(.footnote)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }

            if isExpired {
                EmptyView()
            } else if #available(iOS 26.0, *) {
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
