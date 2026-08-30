import SwiftUI
import SanchrShared

// MARK: - Chat Input Bar
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor (Task 7).
// Owns the reply banner + text field + attachment/emoji toggle + send / voice composer.
// Picker sheets (attachment, camera, emoji, sticker) remain presented by the root
// `ChatDetailView` — this subview only mutates the shared `show*Picker` flags (via
// `@Binding`) or calls intent closures for surfaces it doesn't host directly.
//
// Focus state (`@FocusState isInputFocused`) stays on the root because the root's
// `.onChange(of: isInputFocused)` handler coordinates typing-indicator lifecycle and
// picker-tray dismissal. It is passed in via `@FocusState.Binding`.

@MainActor
struct ChatInputBarView: View {
    let conversation: Conversation
    @Bindable var input: ChatInputState
    @FocusState.Binding var isInputFocused: Bool
    var voicePlayback: VoicePlaybackController
    @Binding var activeTray: ComposerTray?
    var enterSendsMessage: Bool
    var attachmentSendContext: () -> ChatDetailViewModel.AttachmentSendContext
    /// Narrow callbacks so the composer doesn't need a reference to the full
    /// view model. The root constructs these once from its owned `viewModel`.
    var onSendText: () async -> Void
    var onInputTextChanged: (String) -> Void
    var onSendIntent: (AttachmentIntent, ChatDetailViewModel.AttachmentSendContext) async -> Void
    var onClearReply: () -> Void

    @Environment(DependencyContainer.self) private var container

    var body: some View {
        VStack(spacing: 0) {
            // Reply banner
            if let replyMessage = input.replyingToMessage {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SanchrColors.primary)
                        .frame(width: 3, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(replyMessage.isOutgoing ? "You" : conversation.displayName)
                            .font(SanchrTypography.captionSmall)
                            .fontWeight(.semibold)
                            .foregroundColor(SanchrColors.primary)
                            .lineLimit(1)

                        Text(Self.replyPreviewText(replyMessage))
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            onClearReply()
                        }
                    } label: {
                        Group {
                            if #available(iOS 26.0, *) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                                    .frame(width: 24, height: 24)
                                    .sanchrGlass(role: .toolbarButton, interactive: true)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // Read as one unit, so VoiceOver announces who is being
                // replied to and what they said rather than three fragments.
                .accessibilityElement(children: .combine)
                .background(SanchrExportColors.surface)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SanchrExportColors.line).frame(height: 1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Single-row adaptive composer
            HStack(alignment: .bottom, spacing: 10) {
                // Plus button — opens attachment sheet
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if activeTray == .attachments {
                            activeTray = nil
                        } else {
                            isInputFocused = false
                            activeTray = .attachments
                        }
                    }
                } label: {
                    Group {
                        if #available(iOS 26.0, *) {
                            Image(systemName: activeTray == .attachments ? "xmark" : "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(SanchrColors.primary)
                                .frame(width: 36, height: 36)
                                .sanchrGlass(
                                    role: .floatingAction,
                                    interactive: true,
                                    prominence: .prominent,
                                    tint: SanchrColors.primary.opacity(0.18)
                                )
                        } else {
                            Image(systemName: activeTray == .attachments ? "xmark" : "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(SanchrColors.primary)
                                .frame(width: 36, height: 36)
                                .background(SanchrColors.primary.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                }
                .buttonStyle(.plain)
                // Icon-only, so the symbol name is all VoiceOver had.
                .accessibilityLabel(activeTray == .attachments ? "Close attachments" : "Attachments")
                .accessibilityHint("Send a photo, video, document, location or contact.")

                // Text input field
                HStack(spacing: 6) {
                    TextField("Message...", text: $input.inputText, axis: .vertical)
                        .font(SanchrTypography.messageBubbleText)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isInputFocused)
                        .accessibilityLabel("Message")
                        .onSubmit {
                            if enterSendsMessage {
                                Task { await onSendText() }
                            } else {
                                input.inputText += "\n"
                            }
                        }

                    if !hasInput {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if activeTray == .emoji {
                                    activeTray = nil
                                } else {
                                    isInputFocused = false
                                    activeTray = .emoji
                                }
                            }
                        } label: {
                            Image(systemName: activeTray == .emoji ? "keyboard" : "face.smiling")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(SanchrExportColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        // The glyph flips between a face and a keyboard, so
                        // the label has to flip with it or it describes the
                        // wrong action half the time.
                        .accessibilityLabel(activeTray == .emoji ? "Show keyboard" : "Emoji")
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            isInputFocused ? SanchrColors.primary.opacity(0.4) : SanchrExportColors.line.opacity(0.6),
                            lineWidth: 1
                        )
                }

                // Right button: mic (empty) or send (has text)
                if hasInput {
                    // Send button
                    Button {
                        Task { await onSendText() }
                    } label: {
                        Group {
                            if #available(iOS 26.0, *) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .sanchrGlass(
                                        role: .floatingAction,
                                        interactive: true,
                                        prominence: .prominent,
                                        tint: SanchrColors.primary
                                    )
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        LinearGradient(
                                            colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .clipShape(Circle())
                                    .shadow(color: SanchrColors.primary.opacity(0.25), radius: 8, x: 0, y: 3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                    // Guards the window between tapping send and the composer
                    // clearing, which is the only moment a second tap could
                    // land on a button that is about to disappear.
                    .disabled(input.isSending)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    VoiceMessageComposer(
                        playback: voicePlayback,
                        onActivate: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isInputFocused = false
                                activeTray = nil
                            }
                        },
                        onSend: { url, durationMs, waveform in
                            let ctx = attachmentSendContext()
                            Task { @MainActor in
                                await onSendIntent(
                                    .voice(VoiceClip(url: url, durationMs: durationMs, waveform: waveform)),
                                    ctx
                                )
                            }
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: hasInput)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(SanchrExportColors.background.ignoresSafeArea(edges: .bottom))
        .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: -4)
        .onChange(of: input.inputText) { _, newValue in
            onInputTextChanged(newValue)
        }
    }

    private var hasInput: Bool {
        !input.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Preview label rendered in the reply banner. Static so it can be used from
    /// the view body without capturing `self` or re-introducing a root-level helper.
    static func replyPreviewText(_ message: Message) -> String {
        switch message.content {
        case .text(let text): return text
        case .image(_): return "Photo"
        case .video(_): return "Video"
        case .audio(_): return "Voice message"
        case .document(_): return "Document"
        case .location: return "Location"
        case .contact(let name, _): return "Contact: \(name)"
        case .system(let event): return event.displayLabel
        }
    }
}
