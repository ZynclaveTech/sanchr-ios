import SwiftUI
import WebRTC
import SanchrShared

/// Active call UI with controls for mute, speaker, video, and end call.
/// Matches Figma: call-main.
struct ActiveCallView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    private var contactName: String {
        let value = container.callManager.peerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty {
            return value
        }
        return container.callManager.peerId ?? "Unknown"
    }

    var body: some View {
        let callManager = container.callManager

        ZStack {
            // MARK: - Background
            callBackground(callManager: callManager)

            // MARK: - Remote Video (full screen behind controls)
            if callManager.isVideoEnabled, case .active = callManager.callState {
                RemoteVideoView(callManager: callManager)
                    .ignoresSafeArea()
            }

            // MARK: - Content Overlay
            VStack(spacing: 0) {
                // Top bar with encryption badge
                topBar(callManager: callManager)

                Spacer()

                // Contact info + status (hidden when remote video is active)
                if !callManager.isVideoEnabled || !isActive(callManager.callState) {
                    contactInfoSection(callManager: callManager)
                    Spacer()
                }

                // Local video PiP (top-right, only when video call is active)
                if callManager.isVideoEnabled, case .active = callManager.callState {
                    HStack {
                        Spacer()
                        LocalVideoView(callManager: callManager)
                            .frame(width: 120, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: SanchrSpacing.sm))
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
                            .padding(.trailing, SanchrSpacing.md)
                    }
                    Spacer()
                }

                // Filter picker — visible only during active video call
                if callManager.isVideoEnabled, case .active = callManager.callState {
                    filterPicker(callManager: callManager)
                        .padding(.bottom, SanchrSpacing.sm)
                }

                // Incoming call buttons or in-call controls
                if case .incoming = callManager.callState {
                    incomingCallButtons(callManager: callManager)
                } else {
                    callControls(callManager: callManager)
                }

                // End call button (not shown for incoming, they have accept/decline)
                if !(isIncoming(callManager.callState)) {
                    endCallButton(callManager: callManager)
                }
            }
            .padding(.bottom, SanchrSpacing.xxxxl)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(callManager.isVideoEnabled && isActive(callManager.callState))
        .onChange(of: callManager.callState) { _, newState in
            switch newState {
            case .idle:
                dismiss()
            case .ended:
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    dismiss()
                }
            default:
                break
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private func callBackground(callManager: CallManager) -> some View {
        if callManager.isVideoEnabled, case .active = callManager.callState {
            Color.black.ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [
                    Color(hex: 0x1A1033),
                    Color(hex: 0x0F0F1A),
                    Color(hex: 0x0A0A14),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Top Bar

    private func topBar(callManager: CallManager) -> some View {
        HStack {
            Spacer()
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
            .modifier(CallEncryptionBadgeModifier())
            Spacer()
        }
        .padding(.top, SanchrSpacing.md)
    }

    // MARK: - Contact Info

    private func contactInfoSection(callManager: CallManager) -> some View {
        VStack(spacing: SanchrSpacing.md) {
            // Avatar with pulse animation when ringing/connecting
            ZStack {
                if isRingingOrOutgoing(callManager.callState) {
                    PulseRingView()
                }
                Circle()
                    .fill(Color.sanchrPrimary.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .overlay {
                        Text(contactName.prefix(1).uppercased())
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundColor(.sanchrPrimary)
                    }
            }

            Text(contactName)
                .font(SanchrTypography.screenTitle)
                .foregroundColor(.white)

            Text(callStatusText(callManager: callManager))
                .font(SanchrTypography.body)
                .foregroundColor(.white.opacity(0.7))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: callManager.callDuration)
        }
    }

    // MARK: - In-Call Controls

    private func callControls(callManager: CallManager) -> some View {
        SanchrGlassCluster(spacing: 14) {
            HStack(spacing: SanchrSpacing.xxxl) {
                // Mute
                CallControlButton(
                    icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: callManager.isMuted ? "Unmute" : "Mute",
                    isActive: callManager.isMuted
                ) {
                    callManager.toggleMute()
                }

                // Speaker
                CallControlButton(
                    icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    label: "Speaker",
                    isActive: callManager.isSpeakerOn
                ) {
                    callManager.toggleSpeaker()
                }

                // Video toggle
                CallControlButton(
                    icon: callManager.isVideoEnabled ? "video.fill" : "video.slash.fill",
                    label: "Video",
                    isActive: callManager.isVideoEnabled
                ) {
                    callManager.toggleVideo()
                }

                // Flip camera (only when video is on)
                if callManager.isVideoEnabled {
                    CallControlButton(
                        icon: "camera.rotate.fill",
                        label: "Flip",
                        isActive: false
                    ) {
                        callManager.switchCamera()
                    }
                }
            }
        }
        .padding(.bottom, SanchrSpacing.xxl)
    }

    // MARK: - Incoming Call Buttons

    private func incomingCallButtons(callManager: CallManager) -> some View {
        HStack(spacing: SanchrSpacing.mega) {
            // Decline
            VStack(spacing: SanchrSpacing.xs) {
                Button {
                    callManager.declineCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .frame(width: 72, height: 72)
                        .background(SanchrGradients.callDecline)
                        .clipShape(Circle())
                }
                Text("Decline")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.7))
            }

            // Accept
            VStack(spacing: SanchrSpacing.xs) {
                Button {
                    Task {
                        try? await callManager.answerCall()
                    }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .frame(width: 72, height: 72)
                        .background(SanchrGradients.callAccept)
                        .clipShape(Circle())
                }
                Text("Accept")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.bottom, SanchrSpacing.xxxxl)
    }

    // MARK: - End Call Button

    private func endCallButton(callManager: CallManager) -> some View {
        Button {
            callManager.endCall()
        } label: {
            Image(systemName: "phone.down.fill")
                .font(.title)
                .foregroundColor(.white)
                .frame(width: 72, height: 72)
                .background(SanchrGradients.callDecline)
                .clipShape(Circle())
                .shadow(color: SanchrColors.error.opacity(0.4), radius: 12, x: 0, y: 4)
        }
        .sensoryFeedback(.impact(flexibility: .solid), trigger: callManager.callState)
    }

    // MARK: - Filter Picker

    private func filterPicker(callManager: CallManager) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SanchrSpacing.sm) {
                ForEach(VideoFilter.allCases) { filter in
                    Button {
                        callManager.setVideoFilter(filter)
                    } label: {
                        VStack(spacing: SanchrSpacing.xxs) {
                            ZStack {
                                Circle()
                                    .fill(
                                        callManager.currentVideoFilter == filter
                                            ? Color.sanchrPrimary
                                            : Color.white.opacity(0.15)
                                    )
                                    .frame(width: 48, height: 48)
                                Image(systemName: filterIcon(for: filter))
                                    .foregroundStyle(.white)
                                    .font(SanchrTypography.bodyLarge)
                            }
                            Text(filter.displayName)
                                .font(SanchrTypography.captionSmall)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.displayName) filter")
                    .accessibilityValue(callManager.currentVideoFilter == filter ? "selected" : "")
                    .accessibilityHint("Apply filter")
                }
            }
            .padding(.horizontal, SanchrSpacing.md)
        }
    }

    private func filterIcon(for filter: VideoFilter) -> String {
        switch filter {
        case .none:          return "camera"
        case .smoothSkin:    return "sparkles"
        case .warm:          return "sun.max"
        case .cool:          return "snowflake"
        case .blackAndWhite: return "circle.lefthalf.filled"
        case .vivid:         return "paintpalette"
        }
    }

    // MARK: - Status Text

    private func callStatusText(callManager: CallManager) -> String {
        switch callManager.callState {
        case .idle:
            return ""
        case .outgoing:
            return "Calling..."
        case .incoming:
            return "Incoming \(callManager.callType) call"
        case .ringing:
            return "Ringing..."
        case .active:
            return Date.callDuration(seconds: callManager.callDuration)
        case .reconnecting:
            return "Reconnecting..."
        case .ended(_, let reason):
            switch reason {
            case .normal: return "Call ended"
            case .busy: return "Busy"
            case .declined: return "Declined"
            case .failed: return "Call failed"
            case .timeout: return "No answer"
            case .networkError: return "Connection lost"
            }
        }
    }

    // MARK: - State Helpers

    private func isActive(_ state: CallState) -> Bool {
        if case .active = state { return true }
        return false
    }

    private func isIncoming(_ state: CallState) -> Bool {
        if case .incoming = state { return true }
        return false
    }

    private func isRingingOrOutgoing(_ state: CallState) -> Bool {
        switch state {
        case .outgoing, .ringing: return true
        default: return false
        }
    }
}

// MARK: - Pulse Ring Animation

struct PulseRingView: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.sanchrPrimary.opacity(0.3), lineWidth: 2)
                    .frame(width: 120, height: 120)
                    .scaleEffect(isPulsing ? 1.6 + CGFloat(index) * 0.15 : 1.0)
                    .opacity(isPulsing ? 0 : 0.6)
                    .animation(
                        .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.3),
                        value: isPulsing
                    )
            }
        }
        .onAppear { isPulsing = true }
    }
}

// MARK: - Call Control Button

struct CallControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                isPressed = true
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation { isPressed = false }
            }
        }) {
            VStack(spacing: SanchrSpacing.xxs) {
                Group {
                    if #available(iOS 26.0, *) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .scaleEffect(isPressed ? 0.9 : 1.0)
                            .sanchrGlass(
                                role: .floatingAction,
                                interactive: true,
                                prominence: isActive ? .prominent : .regular,
                                tint: isActive ? Color.sanchrPrimary.opacity(0.3) : Color.white.opacity(0.1)
                            )
                    } else {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(isActive ? .white : .white.opacity(0.9))
                            .frame(width: 56, height: 56)
                            .background(
                                isActive
                                    ? Color.sanchrPrimary
                                    : Color.white.opacity(0.15)
                            )
                            .clipShape(Circle())
                            .scaleEffect(isPressed ? 0.9 : 1.0)
                    }
                }

                Text(label)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}

private struct CallEncryptionBadgeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.sanchrGlass(
                role: .chip,
                tint: Color.white.opacity(0.12)
            )
        } else {
            content
                .background(SanchrColors.encryptionBadge)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Video Views (UIViewRepresentable wrappers for RTCMTLVideoView)

struct LocalVideoView: UIViewRepresentable {
    let callManager: CallManager

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        view.transform = CGAffineTransform(scaleX: -1, y: 1)  // Mirror front camera
        callManager.attachLocalRenderer(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
        // Renderer will be cleaned up when CallManager closes WebRTC
    }
}

struct RemoteVideoView: UIViewRepresentable {
    let callManager: CallManager

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        callManager.attachRemoteRenderer(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
        // Renderer will be cleaned up when CallManager closes WebRTC
    }
}
