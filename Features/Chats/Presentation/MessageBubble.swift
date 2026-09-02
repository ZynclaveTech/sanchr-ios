import SwiftUI
import SanchrShared

// MARK: - MessageBubble
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

struct MessageBubble: View {
    @Environment(\.messageAvailableWidth) private var availableWidth
    @Environment(\.colorScheme) private var colorScheme

    /// The host (the message collection view) publishes its width; the
    /// screen is only a fallback for previews and tests.
    private var bubbleMaxWidth: CGFloat {
        (availableWidth ?? UIScreen.main.bounds.width) * SanchrSpacing.messageMaxWidthFraction
    }

    let message: Message
    /// What this message is answering, when the target is still in the
    /// transcript. Resolved by the collection controller — the bubble has no
    /// access to the surrounding messages.
    var replyQuote: ReplyQuote?
    var uploadProgress: Double?
    var uploadLabel: String?
    var hideTimestamp: Bool = false
    var isGroupedWithPrev: Bool = false
    var isGroupedWithNext: Bool = false
    var voicePlayback: VoicePlaybackController
    /// Highlights the viewer's own reaction in the pill.
    var localUserId: String?
    var onBubbleTap: (MessageInteraction) -> Void = { _ in }

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @AppStorage("sanchr.fontSize") private var fontSize = "medium"
    @AppStorage("sanchr.chatBubbleStyle") private var bubbleStyle = "modern"
    @AppStorage("sanchr.linkPreviews") private var showLinkPreviews = true

    private var bubbleFont: Font {
        switch fontSize {
        case "small": return SanchrTypography.caption
        case "large": return SanchrTypography.bodyLarge
        default:      return SanchrTypography.body
        }
    }

    /// How far the pill hangs below the bubble's edge. Half of it sits on the
    /// bubble and half below, which is what makes it read as attached rather
    /// than as a separate row.
    private static let reactionOverhang: CGFloat = 12

    private var bubbleCornerRadius: CGFloat {
        switch bubbleStyle {
        case "classic": return SanchrSpacing.bubblePillRadius
        case "compact": return SanchrSpacing.bubbleCompactRadius
        default:        return SanchrSpacing.bubbleMainRadius
        }
    }

    var body: some View {
        if case .system(let event) = message.content {
            // Centered system event pill
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? SanchrColors.securityEventIconDark : SanchrColors.securityEventIcon)
                    Text(systemEventLabel(event))
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.medium)
                        .foregroundColor(colorScheme == .dark ? SanchrColors.securityEventTextDark : SanchrColors.securityEventText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(colorScheme == .dark ? SanchrColors.securityEventBgDark : SanchrColors.securityEventBg)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(colorScheme == .dark ? SanchrColors.securityEventBorderDark : SanchrColors.securityEventBorder, lineWidth: 1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .bottom) {
                if message.isOutgoing { Spacer(minLength: 0) }

                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
                    // Media already draws a rounded rectangle of its own, at
                    // its own size. A padded, shadowed, stroked bubble behind
                    // it is a second rounded rectangle a few points larger,
                    // visible only as a rim. See `BubbleChrome`.
                    QuotedBubbleLayout {
                        if message.replyToMessageId != nil {
                            replyCard
                        }

                        messageContent
                            .padding(.horizontal, chrome.padsContent ? SanchrSpacing.bubbleHPadding : 0)
                            .padding(.vertical, chrome.padsContent ? SanchrSpacing.bubbleVPadding : 0)
                    }
                        .background {
                            if chrome.drawsBackground {
                                bubbleBackground.clipShape(bubbleShape)
                            }
                        }
                        .clipShape(bubbleShape)
                        .shadow(
                            color: chrome.drawsBackground
                                ? (message.isOutgoing
                                    ? Color.black.opacity(0.1)
                                    : Color.black.opacity(0.04))
                                : .clear,
                            radius: message.isOutgoing ? 6 : 3,
                            x: 0,
                            y: message.isOutgoing ? 2 : 1
                        )
                        .overlay {
                            if !message.isOutgoing, chrome.drawsBackground {
                                bubbleShape
                                    .stroke(SanchrExportColors.line, lineWidth: 1)
                            }
                        }
                        // On the bubble's lower outer corner, straddling the
                        // edge — Signal's placement, and it keeps the pill off
                        // the last line of text.
                        .overlay(alignment: message.isOutgoing ? .bottomLeading : .bottomTrailing) {
                            if !message.reactions.isEmpty {
                                MessageReactionsPill(
                                    reactions: message.reactions,
                                    isOutgoing: message.isOutgoing,
                                    localUserId: localUserId,
                                    onTap: { emoji in
                                        onBubbleTap(
                                            .toggleReaction(messageId: message.id, emoji: emoji)
                                        )
                                    }
                                )
                                .offset(x: message.isOutgoing ? -8 : 8, y: Self.reactionOverhang)
                            }
                        }
                        // An overlay adds no height, so without this the pill
                        // would hang over the timestamp and the message below.
                        .padding(.bottom, message.reactions.isEmpty ? 0 : Self.reactionOverhang * 2)

                    if !hideTimestamp {
                        timestampRow
                            .padding(.top, 4)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: bubbleMaxWidth, alignment: message.isOutgoing ? .trailing : .leading)

                if !message.isOutgoing { Spacer(minLength: 0) }
            }
        }
    }

    private func systemEventLabel(_ event: Message.SystemEvent) -> String {
        event.displayLabel
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .text(let text):
            if let emoji = BubbleChromePolicy.jumboEmoji(in: text) {
                // A message that is nothing but emoji is a gesture, not a
                // sentence. Both Signal and WhatsApp drop the bubble and draw
                // it large; at body size in a bubble it reads as punctuation.
                Text(emoji)
                    .font(.system(size: BubbleChromePolicy.jumboEmojiSize(for: emoji)))
                    // Emoji render from a colour font, so the bubble's white
                    // foreground never applied to them anyway — but it does
                    // apply to any variation selector that falls back to text.
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .accessibilityLabel(emoji)
            } else if let fallback = AttachmentFallbackParser.parse(text) {
                switch fallback {
                case .contact(let name, let phone):
                    if let phone, !phone.isEmpty {
                        contactFallbackBubble(name: name)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onBubbleTap(.openContact(name: name, phoneNumber: phone))
                            }
                    } else {
                        // Legacy payload without a phone — nothing actionable.
                        contactFallbackBubble(name: name)
                    }
                case .location(let lat, let lng):
                    locationFallbackBubble(latitude: lat, longitude: lng)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onBubbleTap(.openLocation(latitude: lat, longitude: lng))
                        }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(bubbleFont)
                        .foregroundColor(messageTextColor)
                        .multilineTextAlignment(.leading)

                    if showLinkPreviews, let url = LinkPreviewService.firstURL(in: text) {
                        LinkPreviewCard(url: url, isOutgoing: message.isOutgoing)
                    }
                }
            }

        case .image(let attachment):
            VStack(
                alignment: .leading,
                spacing: Self.mediaSpacing(hasCaption: Self.hasCaption(attachment.first?.caption))
            ) {
            // View-once media must not render its contents in the transcript.
            // Showing a thumbnail defeats the feature before the recipient ever
            // taps: the image is on screen indefinitely, and the delete-after-view
            // step only removes something already seen.
            if let single = attachment.first, single.isViewOnce == true {
                ViewOnceBubble(
                    attachment: single,
                    isVideo: false,
                    isOutgoing: message.isOutgoing,
                    isConsumed: false
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openMedia(messageId: message.id))
                }
            } else if attachment.count > 1 {
                // Several attachments: a collage. View-once is handled above and
                // never reaches here, so an album is always safe to draw.
                MediaAlbumBubble(
                    attachments: attachment,
                    messageId: message.id,
                    conversationId: message.conversationId,
                    isOutgoing: message.isOutgoing,
                    onTapTile: { index in
                        onBubbleTap(
                            .openMedia(messageId: message.id, attachmentIndex: index)
                        )
                    }
                )
                mediaCaption(attachment.caption, mediaWidth: BubbleMediaLayout.maxWidth)
            } else if let single = attachment.first {
                MediaBubbleImage(
                    attachment: single,
                    messageId: message.id,
                    conversationId: message.conversationId,
                    isOutgoing: message.isOutgoing,
                    uploadProgress: uploadProgress,
                    uploadLabel: uploadLabel,
                    squaresBottomCorners: Self.hasCaption(single.caption)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openMedia(messageId: message.id))
                }
                mediaCaption(
                    single.caption,
                    mediaWidth: BubbleMediaLayout.displaySize(for: single).width
                )
            }
            }

        case .video(let attachment):
            VStack(
                alignment: .leading,
                spacing: Self.mediaSpacing(hasCaption: Self.hasCaption(attachment.first?.caption))
            ) {
            if let single = attachment.first, single.isViewOnce == true {
                ViewOnceBubble(
                    attachment: single,
                    isVideo: true,
                    isOutgoing: message.isOutgoing,
                    isConsumed: false
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openMedia(messageId: message.id))
                }
            } else if attachment.count > 1 {
                // Several attachments: a collage. View-once is handled above and
                // never reaches here, so an album is always safe to draw.
                MediaAlbumBubble(
                    attachments: attachment,
                    messageId: message.id,
                    conversationId: message.conversationId,
                    isOutgoing: message.isOutgoing,
                    onTapTile: { index in
                        onBubbleTap(
                            .openMedia(messageId: message.id, attachmentIndex: index)
                        )
                    }
                )
                mediaCaption(attachment.caption, mediaWidth: BubbleMediaLayout.maxWidth)
            } else if let single = attachment.first {
                MediaBubbleImage(
                    attachment: single,
                    messageId: message.id,
                    conversationId: message.conversationId,
                    isOutgoing: message.isOutgoing,
                    uploadProgress: uploadProgress,
                    uploadLabel: uploadLabel,
                    showsPlayGlyph: true,
                    squaresBottomCorners: Self.hasCaption(single.caption)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openMedia(messageId: message.id))
                }
                mediaCaption(
                    single.caption,
                    mediaWidth: BubbleMediaLayout.displaySize(for: single).width
                )
            }
            }

        case .audio(let media):
            // Voice notes are always a single recording.
            let attachment = media.first
            if attachment?.isVoiceMessage == true,
               let attachment,
               let durationMs = attachment.audioDurationMs {
                VoicePlaybackBubble(
                    messageId: message.id,
                    attachment: attachment,
                    durationMs: durationMs,
                    waveform: attachment.audioWaveform ?? [],
                    isOutgoing: message.isOutgoing,
                    playback: voicePlayback
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20))
                        .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
                    Text(formatDuration(attachment?.durationSeconds ?? 0))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(messageTextColor)
                }
            }

        case .document(let media):
            // A document message carries exactly one file.
            if let attachment = media.first {
                HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename ?? attachment.url.lastPathComponent)
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.semibold)
                        .foregroundColor(messageTextColor)
                        .lineLimit(1)
                    Text(formatFileSize(attachment.sizeBytes))
                        .font(SanchrTypography.micro)
                        .foregroundColor(messageTextColor.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openDocument(messageId: message.id))
                }
            }

        case .location(let latitude, let longitude):
            locationFallbackBubble(latitude: latitude, longitude: longitude)
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openLocation(latitude: latitude, longitude: longitude))
                }

        case .contact(let name, let phoneNumber):
            contactFallbackBubble(name: name)
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openContact(name: name, phoneNumber: phoneNumber))
                }

        default:
            Text("[Unsupported content]")
                .font(SanchrTypography.caption)
                .foregroundColor(messageTextColor.opacity(0.72))
        }
    }

    /// Whether this media carries a caption, and so shares its bubble with
    /// text below it. The corners and the spacing both follow from this, and
    /// they have to agree: a squared corner with a gap under it looks worse
    /// than either alone.
    static func hasCaption(_ caption: String?) -> Bool {
        guard let caption else { return false }
        return !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// No gap when a caption follows, so the picture and the text meet.
    static func mediaSpacing(hasCaption: Bool) -> CGFloat {
        hasCaption ? 0 : 6
    }

    /// Caption drawn beneath media.
    ///
    /// Captions have always been collected, sent and stored, and never shown:
    /// no media bubble rendered `attachment.caption` at all, so anything typed
    /// on the caption or review screen simply vanished on arrival. Constrained
    /// to the media's own width so the bubble does not grow wider than the
    /// picture it belongs to.
    /// Carries its own padding: with a caption the bubble is back, but the
    /// media sits flush to its edges, so the container pads nothing and the
    /// inset belongs to the text.
    @ViewBuilder
    private func mediaCaption(_ caption: String?, mediaWidth: CGFloat) -> some View {
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(caption)
                .font(SanchrTypography.messageBubbleText)
                .foregroundColor(messageTextColor)
                .fixedSize(horizontal: false, vertical: true)
                // The caption plus its own inset must come to exactly the
                // media's width, or the bubble grows wider than the photo and
                // the photo stops being flush with the edge it is supposed to
                // meet.
                .frame(
                    maxWidth: BubbleChromePolicy.captionWidth(forMediaWidth: mediaWidth),
                    alignment: .leading
                )
                .padding(.horizontal, SanchrSpacing.bubbleHPadding)
                // The inset above belongs to the text, not to the stack.
                //
                // A stack gap would show bubble colour between the picture and
                // the caption — the seam that squaring the corners was meant
                // to remove. Padding the text instead keeps them touching
                // while giving the words somewhere to sit: without it the
                // first line rested directly on the photo's bottom edge.
                .padding(.top, SanchrSpacing.bubbleVPadding)
                .padding(.bottom, SanchrSpacing.bubbleVPadding)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        Self.fileSizeFormatter.string(fromByteCount: bytes)
    }

    @ViewBuilder
    private func contactFallbackBubble(name: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(bubbleFont)
                    .fontWeight(.semibold)
                    .foregroundColor(messageTextColor)
                    .lineLimit(2)
                Text("Contact")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(messageTextColor.opacity(0.7))
            }
        }
    }

    /// Privacy contract: this view MUST NOT use MapKit, MKMapView,
    /// MKMapSnapshotter, CLGeocoder, or any reverse-geocoding API. The
    /// receiver only ever sees the raw lat/lng numbers, never a place name.
    @ViewBuilder
    private func locationFallbackBubble(latitude: Double, longitude: Double) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 28))
                .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Location")
                    .font(bubbleFont)
                    .fontWeight(.semibold)
                    .foregroundColor(messageTextColor)
                Text("\(String(format: "%.4f", latitude)), \(String(format: "%.4f", longitude))")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(messageTextColor.opacity(0.7))
            }
        }
    }

    private var timestampRow: some View {
        HStack(spacing: 4) {
            Text(message.timestamp.messageTime)
                .font(SanchrTypography.messageTimestamp)
                .foregroundColor(SanchrExportColors.textTertiary)

            if message.isOutgoing {
                if isDoubleCheck {
                    ZStack(alignment: .leading) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .medium))
                            .offset(x: 5)
                    }
                    .foregroundColor(
                        message.status == .read
                            ? SanchrColors.accent
                            : SanchrExportColors.textTertiary
                    )
                    .frame(width: 16)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
            }
        }
    }

    private var chrome: BubbleChrome {
        let base = BubbleChromePolicy.chrome(for: message.content)
        // A quote needs something to sit on. Bare content — jumbo emoji, or
        // media that draws its own shape — has no bubble, which would leave
        // the card floating on the transcript with nothing tying it to the
        // message it belongs to. `.media` keeps the content flush to the
        // edges, so only the container comes back, not the inset.
        guard message.replyToMessageId != nil, base == .none else { return base }
        return .media
    }

    // MARK: - Quoted reply

    /// The quoted message, drawn inside the bubble.
    ///
    /// It used to sit above the bubble on the transcript background, which
    /// left a reply reading as two separate objects and made the quote compete
    /// with the message rather than belong to it. Signal puts it inside, and
    /// this follows `CVQuotedMessageView`: a stripe down the leading edge, a
    /// tint over the bubble's own fill, the author named in semibold above a
    /// single line of what they said — all in the bubble's own text colour
    /// rather than a grey that would only be legible on one of the two fills.
    ///
    /// The corners echo Signal too: wide where the card meets the bubble's
    /// outer edge, sharp where it meets the message below.
    private var replyCard: some View {
        HStack(spacing: Self.quoteStripeGap) {
            Rectangle()
                .fill(quoteStripeColor)
                .frame(width: Self.quoteStripeThickness)

            VStack(alignment: .leading, spacing: 2) {
                Text(replyQuote?.authorName ?? "Reply")
                    .font(SanchrTypography.captionSmall)
                    .fontWeight(.semibold)
                    .foregroundColor(messageTextColor)
                    .lineLimit(1)

                // Falls back only when the quoted message is not in the
                // transcript — scrolled out of the loaded window, or deleted.
                Text(replyQuote?.preview ?? "Replied to a message")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(messageTextColor.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(quoteTintColor)
        .clipShape(
            .rect(
                topLeadingRadius: Self.quoteWideRadius,
                bottomLeadingRadius: Self.quoteSharpRadius,
                bottomTrailingRadius: Self.quoteSharpRadius,
                topTrailingRadius: Self.quoteWideRadius
            )
        )
        .padding(.horizontal, Self.quoteInset)
        .padding(.top, Self.quoteInset)
        .padding(.bottom, 2)
        // Read as one unit: "Ravi, see you at six" rather than two fragments
        // with no stated relationship.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Replying to \(replyQuote?.authorName ?? "a message"): "
                + (replyQuote?.preview ?? "message unavailable")
        )
    }

    /// Signal's `stripeThickness`, `sharpCornerRadius` and `wideCornerRadius`.
    private static let quoteStripeThickness: CGFloat = 4
    private static let quoteStripeGap: CGFloat = 8
    private static let quoteSharpRadius: CGFloat = 4
    private static let quoteWideRadius: CGFloat = 10
    private static let quoteInset: CGFloat = 4

    private var quoteStripeColor: Color {
        message.isOutgoing ? .white : SanchrColors.primary
    }

    /// Signal's `backgroundTint`: a wash over the bubble's fill, not a colour
    /// of its own, so it works over both the gradient and the surface.
    private var quoteTintColor: Color {
        message.isOutgoing
            ? Color.white.opacity(0.18)
            : SanchrColors.primary.opacity(0.08)
    }

    private var bubbleBackground: some View {
        Group {
            if message.isOutgoing {
                LinearGradient(
                    colors: [SanchrColors.primary, SanchrColors.primaryDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                SanchrExportColors.surface
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let main = bubbleCornerRadius
        let tail = SanchrSpacing.bubbleTailRadius
        // Signal-style: sharp inner corners on the tail side when messages are clustered
        let sharp: CGFloat = 4
        if message.isOutgoing {
            // Tail is on the trailing side
            return UnevenRoundedRectangle(
                topLeadingRadius: main,
                bottomLeadingRadius: main,
                bottomTrailingRadius: isGroupedWithNext ? sharp : tail,
                topTrailingRadius: isGroupedWithPrev ? sharp : main
            )
        }
        // Tail is on the leading side
        return UnevenRoundedRectangle(
            topLeadingRadius: isGroupedWithPrev ? sharp : main,
            bottomLeadingRadius: isGroupedWithNext ? sharp : tail,
            bottomTrailingRadius: main,
            topTrailingRadius: main
        )
    }

    private var messageTextColor: Color {
        message.isOutgoing ? .white : SanchrExportColors.textPrimary
    }

    private var statusIcon: String {
        switch message.status {
        case .sending:
            return "clock"
        case .sent, .delivered:
            return "checkmark"
        case .read:
            return "checkmark"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    /// Whether to show double-check (delivered/read) vs single-check (sent).
    private var isDoubleCheck: Bool {
        message.status == .delivered || message.status == .read
    }
}
