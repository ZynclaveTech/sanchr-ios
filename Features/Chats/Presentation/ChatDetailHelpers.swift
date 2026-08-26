import Contacts
import SwiftUI
import UIKit
import SanchrShared

// MARK: - Chat Detail Helpers
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.
// Houses leaf helper types with no dependency on ChatDetailView's private state.

// MARK: - Link Preview Card
// Visibility promoted during god-file extraction (used by MessageBubble).
struct LinkPreviewCard: View {
    let url: URL
    let isOutgoing: Bool
    @State private var preview: LinkPreviewData?
    @State private var previewImage: UIImage?
    @State private var isLoading = true

    private static let imageCache = NSCache<NSString, UIImage>()
    private let cardWidth: CGFloat = 220
    private let imageHeight: CGFloat = 120

    var body: some View {
        Group {
            if let preview {
                VStack(alignment: .leading, spacing: 0) {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: imageHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else if preview.imageData != nil {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill((isOutgoing ? Color.white : SanchrExportColors.textPrimary).opacity(0.08))
                            .frame(height: imageHeight)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let title = preview.title, !title.isEmpty {
                            Text(title)
                                .font(SanchrTypography.captionSmall)
                                .fontWeight(.semibold)
                                .foregroundColor(isOutgoing ? Color.white : SanchrExportColors.textPrimary)
                                .lineLimit(2)
                        }

                        Text(preview.domain)
                            .font(SanchrTypography.micro)
                            .foregroundColor(isOutgoing ? Color.white.opacity(0.7) : SanchrExportColors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(
                    isOutgoing
                        ? Color.white.opacity(0.1)
                        : SanchrExportColors.surfaceSoft
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(width: cardWidth, alignment: .leading)
                .onTapGesture {
                    UIApplication.shared.open(url)
                }
            } else if isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((isOutgoing ? Color.white : SanchrExportColors.textPrimary).opacity(0.08))
                        .frame(height: imageHeight)

                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(isOutgoing ? .white : Color.sanchrPrimary)
                        Text(url.host ?? "Loading...")
                            .font(SanchrTypography.micro)
                            .foregroundColor(isOutgoing ? Color.white.opacity(0.6) : SanchrExportColors.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .background(
                    isOutgoing
                        ? Color.white.opacity(0.1)
                        : SanchrExportColors.surfaceSoft
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .task(id: url) {
            let cachedImage = Self.imageCache.object(forKey: url.absoluteString as NSString)
            if let cachedImage {
                previewImage = cachedImage
            }

            let preview = await LinkPreviewService.shared.preview(for: url)
            self.preview = preview
            self.isLoading = false

            guard let preview, let imageData = preview.imageData, previewImage == nil else { return }

            let scale = await MainActor.run { UIScreen.main.scale }
            let targetSize = CGSize(width: cardWidth, height: imageHeight)
            let decodedImage = await Task.detached(priority: .utility) {
                BubbleImagePipeline.downsampleImage(
                    data: imageData,
                    to: targetSize,
                    scale: scale
                )
            }.value

            if let decodedImage {
                Self.imageCache.setObject(decodedImage, forKey: url.absoluteString as NSString)
                previewImage = decodedImage
            }
        }
    }
}

// MARK: - Swipe To Reply Wrapper
private struct SwipeToReplyWrapper<Content: View>: View {
    let message: Message
    let onReply: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    private let threshold: CGFloat = 60

    var body: some View {
        HStack(spacing: 0) {
            content
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onChanged { value in
                            // Only allow right swipe (positive X) for received, left for sent
                            let translation = value.translation.width
                            if message.isOutgoing {
                                offset = min(0, translation) * 0.5 // Left swipe, dampened
                            } else {
                                offset = max(0, translation) * 0.5 // Right swipe, dampened
                            }
                        }
                        .onEnded { value in
                            let swipeAmount = abs(value.translation.width)
                            if swipeAmount > threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onReply()
                            }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                offset = 0
                            }
                        }
                )

            Spacer(minLength: 0)
        }
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            if abs(offset) > 10 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
                    .opacity(min(1, abs(offset) / threshold))
                    .scaleEffect(min(1, abs(offset) / threshold))
            }
        }
    }
}

// MARK: - Viewer HUD Modifier
// Visibility promoted during god-file extraction.
struct ChatViewerHUDModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.sanchrGlass(
                role: .viewerCard,
                tint: Color.white.opacity(0.1)
            )
        } else {
            content
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

// MARK: - Search Field Surface Modifier
// Visibility promoted during god-file extraction.
struct ChatSearchFieldSurfaceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.sanchrGlass(role: .chip, interactive: true)
        } else {
            content
                .background(SanchrExportColors.surfaceSoft)
                .clipShape(Capsule())
        }
    }
}

// MARK: - New Contact Payload
// Visibility promoted during god-file extraction.
/// Identifiable payload used by the "Save to Contacts" `.sheet(item:)`
/// in `ChatDetailView`.
struct NewContactPayload: Identifiable {
    let id = UUID()
    let name: String
    let phone: String
}

// MARK: - Gallery Identified URL Bridge
// Visibility promoted during god-file extraction.
/// Identifiable URL wrapper used by the invite `.sheet(item:)`. Named
/// "Bridge" to avoid colliding with the file-private `GalleryIdentifiedURL`
/// inside `MediaGalleryView.swift`.
struct GalleryIdentifiedURLBridge: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Share Activity View
// Visibility promoted during god-file extraction.
/// Thin `UIActivityViewController` wrapper used by the invite sheet.
/// File-private to `ChatDetailView.swift` — the media gallery has its
/// own copy (`GalleryActivityView`) since cross-file sharing isn't
/// worth the refactor for two 10-line structs.
struct ChatShareActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Bootstrap Contact Repository
// Visibility promoted during god-file extraction.
/// Bootstrap no-op `ContactRepositoryProtocol` used as the initial
/// dependency of `ContactActionCoordinator` when `ChatDetailView` first
/// constructs its `@StateObject`. The coordinator is swapped to the
/// real `container.contactRepository` inside `.task`; every method here
/// is expected to never be called. `fatalError` on the ones that aren't
/// `fetchContacts` so a misuse is loud.
final class BootstrapContactRepository: ContactRepositoryProtocol, @unchecked Sendable {
    func fetchContacts() async throws -> [User] { [] }
    func searchUser(phoneNumber: String) async throws -> User? {
        fatalError("ChatDetailView bootstrap repo should never be called")
    }
    func blockUser(userId: String) async throws {
        fatalError("ChatDetailView bootstrap repo should never be called")
    }
    func unblockUser(userId: String) async throws {
        fatalError("ChatDetailView bootstrap repo should never be called")
    }
    func fetchBlockedUsers() async throws -> [User] {
        fatalError("ChatDetailView bootstrap repo should never be called")
    }
    func updateProfile(
        displayName: String?,
        bio: String?,
        avatarData: Data?
    ) async throws -> User {
        fatalError("ChatDetailView bootstrap repo should never be called")
    }
}

// MARK: - Bootstrap Media Resolver
// Visibility promoted during god-file extraction.
/// Bootstrap `ChatMediaResolving` used as the initial resolver for
/// `DocumentPreviewCoordinator` when `ChatDetailView` first constructs
/// its `@StateObject`. Both methods fatalError — the coordinator is
/// reconfigured with the real `container.chatMediaResolver` inside
/// `.task` before any bubble can be tapped, so nothing should ever hit
/// this path.
final class BootstrapMediaResolver: ChatMediaResolving, @unchecked Sendable {
    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        fatalError("ChatDetailView bootstrap resolver should never be called")
    }
    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        fatalError("ChatDetailView bootstrap resolver should never be called")
    }
}

// MARK: - Device Contact Matcher
/// Device-book lookup helper used by `ContactActionCoordinator` to
/// determine whether a phone is already in the user's native Contacts.
/// Lives here because it's only used from this view; if another view
/// needs it, lift into `Platform`.
struct DeviceContactMatcher {
    static let shared = DeviceContactMatcher()
    func contains(phone: String) -> Bool {
        let store = CNContactStore()
        let keys = [CNContactPhoneNumbersKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let normalizedTarget = ContactDataSource.normalizePhoneNumber(phone)
        var found = false
        try? store.enumerateContacts(with: request) { contact, stop in
            for number in contact.phoneNumbers {
                let candidate = ContactDataSource.normalizePhoneNumber(number.value.stringValue)
                if candidate == normalizedTarget {
                    found = true
                    stop.pointee = true
                    return
                }
            }
        }
        return found
    }
}
