import SwiftUI

/// Active call UI with controls for mute, speaker, and end call.
/// Matches Figma: call-main.
struct ActiveCallView: View {
    let contactName: String
    let isVideo: Bool
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var isMuted = false
    @State private var isSpeakerOn = false
    @State private var callDuration: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            // Background
            Color.sanchrBackground(colorScheme)
                .ignoresSafeArea()

            VStack(spacing: SanchrSpacing.xxxl) {
                Spacer()

                // MARK: - Contact Info
                VStack(spacing: SanchrSpacing.md) {
                    Circle()
                        .fill(Color.sanchrPrimary.opacity(0.2))
                        .frame(width: 96, height: 96)
                        .overlay {
                            Text(contactName.prefix(1).uppercased())
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundColor(.sanchrPrimary)
                        }

                    Text(contactName)
                        .font(SanchrTypography.screenTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Text(Date.callDuration(seconds: callDuration))
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        .monospacedDigit()

                    // Encryption badge
                    HStack(spacing: SanchrSpacing.xxs) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                        Text("End-to-end encrypted")
                            .font(SanchrTypography.captionSmall)
                    }
                    .foregroundColor(SanchrColors.encryptionBadgeText)
                    .padding(.horizontal, SanchrSpacing.sm)
                    .padding(.vertical, SanchrSpacing.xxs)
                    .background(SanchrColors.encryptionBadge)
                    .clipShape(Capsule())
                }

                Spacer()

                // MARK: - Call Controls
                HStack(spacing: SanchrSpacing.xxxl) {
                    // Mute
                    CallControlButton(
                        icon: isMuted ? "mic.slash.fill" : "mic.fill",
                        label: isMuted ? "Unmute" : "Mute",
                        isActive: isMuted
                    ) {
                        isMuted.toggle()
                        Task { await container.callManager.toggleMute() }
                    }

                    // Speaker
                    CallControlButton(
                        icon: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                        label: "Speaker",
                        isActive: isSpeakerOn
                    ) {
                        isSpeakerOn.toggle()
                        Task { await container.callManager.toggleSpeaker() }
                    }

                    if isVideo {
                        // Flip Camera
                        CallControlButton(
                            icon: "camera.rotate.fill",
                            label: "Flip",
                            isActive: false
                        ) {
                            // TODO: Flip camera
                        }
                    }
                }

                // End Call
                Button {
                    Task {
                        try? await container.callManager.endCall(callId: "")
                    }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .frame(width: 72, height: 72)
                        .background(SanchrGradients.callDecline)
                        .clipShape(Circle())
                }
                .padding(.bottom, SanchrSpacing.xxxxl)
            }
        }
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            callDuration += 1
        }
    }
}

// MARK: - Call Control Button

struct CallControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: SanchrSpacing.xxs) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(isActive ? .white : Color.sanchrTextPrimary(colorScheme))
                    .frame(width: 56, height: 56)
                    .background(isActive ? Color.sanchrPrimary : Color.sanchrSurface(colorScheme))
                    .clipShape(Circle())

                Text(label)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }
        }
    }
}
