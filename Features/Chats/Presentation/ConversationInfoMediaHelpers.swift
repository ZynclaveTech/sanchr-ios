@preconcurrency import AVFoundation
import SanchrShared
import SwiftUI
import UIKit

// MARK: - Conversation Info Media Helpers
// Extracted from ConversationInfoView.swift on 2026-04-20 as part of god-file refactor.

// MARK: - Gallery Presentation
// Visibility promoted from private to module-internal for cross-file access.
struct ConversationInfoGalleryPresentation: Identifiable {
    let id = UUID()
    let items: [Message]
    let initialIndex: Int
}

// MARK: - Media Thumbnail
// Visibility promoted from private to module-internal for cross-file access.
struct ConversationInfoMediaThumbnail: View {
    let message: Message
    let resolver: ChatMediaResolving

    @State private var image: UIImage?

    var body: some View {
        // GeometryReader pins the image to the cell's actual bounds so
        // .scaledToFill has a frame to fill instead of overflowing the
        // RoundedRectangle clip. The outer aspectRatio gives the
        // GeometryReader a square layout slot.
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
        case .image(let a), .video(let a): return a
        default: return nil
        }
    }
}

// MARK: - Media Thumbnail Generator
/// Off-main poster-frame generator. Used by inline media thumbnails
/// in ConversationInfoView and the Media tab in SharedContentView so
/// they don't blindly hand a video file to UIImage(contentsOfFile:)
/// (which dumps "createImageAtIndex... could not find plugin" errors
/// to the console for every MP4 in the chat).
enum MediaThumbnailGenerator {
    static func posterFrame(forVideoAt url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                return UIImage(cgImage: cgImage)
            } catch {
                return nil
            }
        }.value
    }
}
