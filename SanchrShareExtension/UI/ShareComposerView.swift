import SwiftUI
import AVFoundation
import ImageIO
import SanchrShared

/// Final review screen before the share extension dispatches the payload
/// to the chosen chats. Renders a preview of the payload, an optional
/// caption field for media payloads, and a row of recipient pills with
/// a primary "Send" button.
///
/// The composer is intentionally read-only with respect to the recipient
/// list — going back to the picker is handled by SwiftUI's navigation
/// stack inside the parent `ShareRootView`. The caption is forwarded as a
/// trimmed optional through `onSend(_:)`.
struct ShareComposerView: View {

    let payload: SharePayload
    let recipients: [ShareChatSummary]
    let onCancel: () -> Void
    let onSend: (String?) -> Void

    @State private var caption: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                if supportsCaption {
                    TextField("Add a caption…", text: $caption, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(12)
                        .background(Color(uiColor: .systemGray6))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                }

                recipientPills

                Spacer(minLength: 0)

                sendButton
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    // MARK: - Recipients

    private var recipientPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recipients) { recipient in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(SanchrColors.primary.opacity(0.15))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text(String(recipient.title.prefix(1)).uppercased())
                                    .font(SanchrTypography.scaled(size: 11, weight: .semibold))
                                    .foregroundColor(SanchrColors.primary)
                            )
                        Text(recipient.title)
                            .font(.caption.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Send button

    private var sendButton: some View {
        Button {
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            onSend(trimmed.isEmpty ? nil : trimmed)
        } label: {
            Text(sendButtonTitle)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [SanchrColors.primary, SanchrColors.primaryDark],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(14)
        }
        .disabled(recipients.isEmpty)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var sendButtonTitle: String {
        switch recipients.count {
        case 0: return "Send"
        case 1: return "Send to \(recipients[0].title)"
        default: return "Send to \(recipients.count) chats"
        }
    }

    // MARK: - Caption affordance

    private var supportsCaption: Bool {
        switch payload {
        case .text, .url:
            return false
        case .image, .video, .audio, .file, .multi:
            return true
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        switch payload {
        case .text(let body):
            ScrollView {
                Text(body)
                    .font(.body)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(uiColor: .systemGray6))

        case .url(let link):
            VStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 36))
                    .foregroundColor(SanchrColors.primary)
                Text(link.absoluteString)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGray6))

        case .image(let url, _):
            imagePreview(at: url)

        case .video(let url, _, let duration):
            videoPreview(at: url, duration: duration)

        case .audio(_, let bytes, let duration):
            filePlaceholder(
                icon: "waveform",
                title: "Voice message",
                detail: "\(formatDuration(duration)) • \(byteString(bytes))"
            )

        case .file(_, let bytes, let filename):
            filePlaceholder(
                icon: "doc",
                title: filename,
                detail: byteString(bytes)
            )

        case .multi(let parts):
            multiPreview(parts: parts)
        }
    }

    @ViewBuilder
    private func imagePreview(at url: URL) -> some View {
        if let image = Self.thumbnailImage(at: url) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            filePlaceholder(icon: "photo", title: "Photo", detail: nil)
        }
    }

    @ViewBuilder
    private func videoPreview(at url: URL, duration: Double) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = Self.videoPosterImage(at: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                filePlaceholder(icon: "video", title: "Video", detail: nil)
            }
            Text(formatDuration(duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(8)
        }
    }

    private func multiPreview(parts: [SharePayload]) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32))
                .foregroundColor(SanchrColors.primary)
            Text("\(parts.count) attachments")
                .font(.headline)
            Text(byteString(parts.reduce(0) { $0 + $1.sizeBytes }))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGray6))
    }

    private func filePlaceholder(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(SanchrColors.primary)
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGray6))
    }

    // MARK: - Formatting helpers

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Image generation (static so they don't capture self)

    private static func thumbnailImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func videoPosterImage(at url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
