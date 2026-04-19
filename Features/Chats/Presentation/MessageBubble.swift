import SwiftUI
import SanchrShared

// MARK: - MessageBubble
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.

struct MessageBubble: View {
    let message: Message
    var uploadProgress: Double?
    var uploadLabel: String?
    var hideTimestamp: Bool = false
    var isGroupedWithPrev: Bool = false
    var isGroupedWithNext: Bool = false
    var voicePlayback: VoicePlaybackController
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
                        .foregroundColor(SanchrColors.securityEventIcon)
                    Text(systemEventLabel(event))
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.medium)
                        .foregroundColor(SanchrColors.securityEventText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(SanchrColors.securityEventBg)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(SanchrColors.securityEventBorder, lineWidth: 1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .bottom) {
                if message.isOutgoing { Spacer(minLength: 0) }

                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
                    if message.replyToMessageId != nil {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(message.isOutgoing ? Color.white.opacity(0.5) : SanchrColors.primary)
                                .frame(width: 3)

                            Text("Replied to a message")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(message.isOutgoing ? Color.white.opacity(0.7) : SanchrExportColors.textSecondary)
                        }
                        .padding(.bottom, 4)
                    }

                    messageContent
                        .padding(.horizontal, SanchrSpacing.bubbleHPadding)
                        .padding(.vertical, SanchrSpacing.bubbleVPadding)
                        .background(bubbleBackground)
                        .clipShape(bubbleShape)
                        .shadow(
                            color: message.isOutgoing
                                ? Color.black.opacity(0.1)
                                : Color.black.opacity(0.04),
                            radius: message.isOutgoing ? 6 : 3,
                            x: 0,
                            y: message.isOutgoing ? 2 : 1
                        )
                        .overlay {
                            if !message.isOutgoing {
                                bubbleShape
                                    .stroke(SanchrExportColors.line, lineWidth: 1)
                            }
                        }

                    if !hideTimestamp {
                        timestampRow
                            .padding(.top, 4)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: UIScreen.main.bounds.width * SanchrSpacing.messageMaxWidthFraction, alignment: message.isOutgoing ? .trailing : .leading)

                if !message.isOutgoing { Spacer(minLength: 0) }
            }
        }
    }

    private func systemEventLabel(_ event: Message.SystemEvent) -> String {
        switch event {
        case .identityKeyChanged: return "Security code changed"
        case .disappearingTimerChanged: return "Disappearing timer changed"
        case .groupCreated: return "Group created"
        case .memberAdded: return "Member added"
        case .memberRemoved: return "Member removed"
        case .screenshotDetected: return "Screenshot detected"
        case .viewOnceConsumed: return "Viewed"
        case .autoVaulted: return "Auto-vaulted media"
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .text(let text):
            if let fallback = AttachmentFallbackParser.parse(text) {
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
            MediaBubbleImage(
                attachment: attachment,
                messageId: message.id,
                conversationId: message.conversationId,
                isOutgoing: message.isOutgoing,
                uploadProgress: uploadProgress,
                uploadLabel: uploadLabel
            )
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openMedia(messageId: message.id))
                }

        case .video(let attachment):
            MediaBubbleImage(
                attachment: attachment,
                messageId: message.id,
                conversationId: message.conversationId,
                isOutgoing: message.isOutgoing,
                uploadProgress: uploadProgress,
                uploadLabel: uploadLabel
            )
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onBubbleTap(.openMedia(messageId: message.id))
                }

        case .audio(let attachment):
            if attachment.isVoiceMessage == true,
               let durationMs = attachment.audioDurationMs {
                VoicePlaybackBubble(
                    messageId: message.id,
                    url: attachment.url,
                    durationMs: durationMs,
                    waveform: attachment.audioWaveform ?? [],
                    playback: voicePlayback
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 20))
                        .foregroundColor(message.isOutgoing ? .white : SanchrColors.primary)
                    Text(formatDuration(attachment.durationSeconds ?? 0))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(messageTextColor)
                }
            }

        case .document(let attachment):
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
