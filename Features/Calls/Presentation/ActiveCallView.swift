import Kingfisher
import SwiftUI
import WebRTC
import SanchrShared

/// Active call UI with controls for mute, speaker, video, and end call.
struct ActiveCallView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsVideoControls = true
    @State private var isTrackingTouch = false
    @State private var controlsAutoHideTask: Task<Void, Never>?

    private var contactName: String {
        let value = container.callManager.peerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty, UUID(uuidString: value) == nil {
            return value
        }
        return "Unknown Caller"
    }

    var body: some View {
        let callManager = container.callManager
        let videoSurface = isVideoSurface(callManager)
        let rendersRemoteVideo = shouldRenderRemoteVideo(callManager)

        ZStack {
            callBackground(isVideoSurface: videoSurface)

            if videoSurface {
                ZStack {
                    RemoteVideoView(callManager: callManager)
                        .ignoresSafeArea()
                        .opacity(rendersRemoteVideo ? 1 : 0)

                    if !rendersRemoteVideo {
                        remoteVideoPlaceholder(callManager: callManager)
                            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: rendersRemoteVideo)
            }

            VStack(spacing: 0) {
                topBar(isVideoSurface: videoSurface)

                if videoSurface {
                    videoCallContent(callManager: callManager)
                } else {
                    audioCallContent(callManager: callManager)
                }
            }
        }
        .preferredColorScheme(videoSurface ? .dark : nil)
        .statusBarHidden(videoSurface)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard videoSurface, !isTrackingTouch else { return }
                    isTrackingTouch = true
                    handleVideoSurfaceTouchBegan(isVideoSurface: videoSurface)
                }
                .onEnded { _ in
                    isTrackingTouch = false
                    scheduleControlsAutoHideIfNeeded(isVideoSurface: videoSurface)
                },
            including: .all
        )
        .alert(
            "Join video call?",
            isPresented: videoUpgradeRequestBinding(callManager: callManager)
        ) {
            Button("Not now", role: .cancel) {
                callManager.declineVideoUpgradeRequest()
            }
            Button("Join") {
                Task {
                    await callManager.acceptVideoUpgradeRequest()
                }
            }
        } message: {
            Text("\(contactName) wants to switch this call to video.")
        }
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
        .onAppear {
            configureControlsAutoHide(isVideoSurface: videoSurface)
        }
        .onChange(of: videoSurface) { _, isVideoSurface in
            configureControlsAutoHide(isVideoSurface: isVideoSurface)
        }
        .onDisappear {
            cancelControlsAutoHide()
        }
    }

    // MARK: - Layout

    private func audioCallContent(callManager: CallManager) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: SanchrSpacing.xxl)

            CallIdentitySection(
                displayName: contactName,
                avatarURL: callManager.peerAvatarURL,
                statusText: callStatusText(callManager: callManager),
                isConnecting: isRingingOrOutgoing(callManager.callState),
                peerIsMuted: callManager.peerIsMuted,
                peerBatteryIsLow: callManager.peerBatteryIsLow,
                isVideoSurface: false
            )
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

            Spacer(minLength: SanchrSpacing.xxl)

            bottomActions(callManager: callManager, isVideoSurface: false)
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                .padding(.bottom, SanchrSpacing.xxl)
        }
    }

    private func videoCallContent(callManager: CallManager) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if callManager.isVideoEnabled {
                    LocalVideoView(callManager: callManager)
                        .frame(width: 112, height: 152)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrSpacing.sm, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SanchrSpacing.sm, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
                        .accessibilityLabel("Local video preview")
                }
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.top, SanchrSpacing.sm)

            Spacer(minLength: SanchrSpacing.lg)

            if showsVideoControls, callManager.isVideoEnabled {
                filterPicker(callManager: callManager, isVideoSurface: true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, SanchrSpacing.sm)
            }

            if showsVideoControls {
                bottomActions(callManager: callManager, isVideoSurface: true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.bottom, SanchrSpacing.xxl)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsVideoControls)
    }

    @ViewBuilder
    private func bottomActions(callManager: CallManager, isVideoSurface: Bool) -> some View {
        if case .incoming = callManager.callState {
            incomingCallButtons(callManager: callManager, isVideoSurface: isVideoSurface)
        } else {
            activeCallDock(callManager: callManager, isVideoSurface: isVideoSurface)
        }
    }

    // MARK: - Background

    private func callBackground(isVideoSurface: Bool) -> some View {
        ZStack {
            if isVideoSurface {
                Color.black
            } else {
                Color.sanchrBackground(colorScheme)

                LinearGradient(
                    colors: [
                        SanchrColors.primary.opacity(colorScheme == .dark ? 0.28 : 0.14),
                        SanchrColors.accent.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.sanchrSurface(colorScheme).opacity(colorScheme == .dark ? 0.56 : 0.72),
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Top Bar

    private func topBar(isVideoSurface: Bool) -> some View {
        HStack {
            Spacer()

            HStack(spacing: SanchrSpacing.xxs) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("End-to-end encrypted")
                    .font(SanchrTypography.captionSmall)
            }
            .foregroundColor(SanchrColors.encryptionBadgeText)
            .padding(.horizontal, SanchrSpacing.sm)
            .padding(.vertical, SanchrSpacing.xxs)
            .modifier(CallEncryptionBadgeModifier(isVideoSurface: isVideoSurface))
            .accessibilityLabel("End-to-end encrypted call")

            Spacer()
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.top, SanchrExportMetrics.topBarTop)
        .padding(.bottom, SanchrSpacing.sm)
    }

    // MARK: - In-Call Controls

    private func activeCallDock(callManager: CallManager, isVideoSurface: Bool) -> some View {
        let videoUpgradeDisabled = callManager.outgoingVideoUpgradePending
        let videoButtonLabel = callManager.outgoingVideoUpgradePending
            ? "Waiting"
            : (callManager.callType == "video" && callManager.isVideoEnabled ? "Camera off" : "Video")

        return CallActionDock(isVideoSurface: isVideoSurface) {
            HStack(alignment: .top, spacing: 0) {
                CallControlButton(
                    icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: callManager.isMuted ? "Unmute" : "Mute",
                    isActive: callManager.isMuted,
                    isVideoSurface: isVideoSurface,
                    accessibilityValue: callManager.isMuted ? "Muted" : "Unmuted"
                ) {
                    callManager.toggleMute()
                }

                CallControlButton(
                    icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    label: callManager.isSpeakerOn ? "Earpiece" : "Speaker",
                    isActive: callManager.isSpeakerOn,
                    isVideoSurface: isVideoSurface,
                    accessibilityValue: callManager.isSpeakerOn ? "Speaker on" : "Earpiece"
                ) {
                    callManager.toggleSpeaker()
                }

                CallControlButton(
                    icon: callManager.callType == "video" && callManager.isVideoEnabled
                        ? "video.fill"
                        : "video.slash.fill",
                    label: videoButtonLabel,
                    isActive: callManager.callType == "video" && callManager.isVideoEnabled,
                    isDisabled: videoUpgradeDisabled,
                    isVideoSurface: isVideoSurface,
                    accessibilityValue: videoUpgradeDisabled ? "Waiting for response" : nil
                ) {
                    callManager.toggleVideo()
                }

                if callManager.isVideoEnabled {
                    CallControlButton(
                        icon: "camera.rotate.fill",
                        label: "Flip",
                        isActive: false,
                        isVideoSurface: isVideoSurface
                    ) {
                        callManager.switchCamera()
                    }
                }

                CallControlButton(
                    icon: "phone.down.fill",
                    label: "End",
                    isActive: false,
                    isDestructive: true,
                    isVideoSurface: isVideoSurface
                ) {
                    callManager.endCall()
                }
                .sensoryFeedback(.impact(flexibility: .solid), trigger: callManager.callState)
            }
        }
    }

    private func incomingCallButtons(callManager: CallManager, isVideoSurface: Bool) -> some View {
        CallActionDock(isVideoSurface: isVideoSurface) {
            HStack(alignment: .top, spacing: 0) {
                IncomingCallButton(
                    icon: "phone.down.fill",
                    label: "Decline",
                    tint: SanchrColors.error,
                    accessibilityLabel: "Decline call"
                ) {
                    callManager.declineCall()
                }

                IncomingCallButton(
                    icon: "phone.fill",
                    label: "Accept",
                    tint: SanchrColors.success,
                    accessibilityLabel: "Accept call"
                ) {
                    Task {
                        try? await callManager.requestAnswerCall()
                    }
                }
            }
        }
    }

    // MARK: - Filter Picker

    private func filterPicker(callManager: CallManager, isVideoSurface: Bool) -> some View {
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
                                            ? SanchrColors.primary
                                            : Color.white.opacity(isVideoSurface ? 0.16 : 0.10)
                                    )
                                    .frame(width: 48, height: 48)
                                Image(systemName: filterIcon(for: filter))
                                    .foregroundStyle(.white)
                                    .font(SanchrTypography.bodyLarge)
                            }
                            Text(filter.displayName)
                                .font(SanchrTypography.captionSmall)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.displayName) filter")
                    .accessibilityValue(callManager.currentVideoFilter == filter ? "Selected" : "")
                    .accessibilityHint("Apply filter")
                }
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
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
            case .cancelled: return "Cancelled"
            }
        }
    }

    // MARK: - State Helpers

    private func isVideoSurface(_ callManager: CallManager) -> Bool {
        callManager.callType == "video" && isActive(callManager.callState)
    }

    private func isActive(_ state: CallState) -> Bool {
        if case .active = state { return true }
        return false
    }

    private func isRingingOrOutgoing(_ state: CallState) -> Bool {
        switch state {
        case .outgoing, .ringing: return true
        default: return false
        }
    }

    private func videoUpgradeRequestBinding(callManager: CallManager) -> Binding<Bool> {
        Binding(
            get: { callManager.incomingVideoUpgradeRequest },
            set: { _ in }
        )
    }

    private func shouldRenderRemoteVideo(_ callManager: CallManager) -> Bool {
        callManager.peerVideoEnabled && callManager.hasRemoteVideoTrack
    }

    private func remoteVideoPlaceholder(callManager: CallManager) -> some View {
        VStack {
            Spacer()

            CallIdentitySection(
                displayName: contactName,
                avatarURL: callManager.peerAvatarURL,
                statusText: remoteVideoPlaceholderStatusText(callManager: callManager),
                isConnecting: false,
                peerIsMuted: callManager.peerIsMuted,
                peerBatteryIsLow: callManager.peerBatteryIsLow,
                peerVideoDisabled: !callManager.peerVideoEnabled,
                isVideoSurface: true
            )

            Spacer()
        }
    }

    private func remoteVideoPlaceholderStatusText(callManager: CallManager) -> String {
        if callManager.peerVideoEnabled {
            return "Connecting video..."
        }
        return callStatusText(callManager: callManager)
    }

    private func handleVideoSurfaceTouchBegan(isVideoSurface: Bool) {
        guard isVideoSurface else { return }
        cancelControlsAutoHide()

        if !showsVideoControls {
            withAnimation(.easeInOut(duration: 0.2)) {
                showsVideoControls = true
            }
        }
    }

    private func configureControlsAutoHide(isVideoSurface: Bool) {
        if isVideoSurface {
            showsVideoControls = true
            scheduleControlsAutoHideIfNeeded(isVideoSurface: true)
        } else {
            showsVideoControls = true
            cancelControlsAutoHide()
        }
    }

    private func scheduleControlsAutoHideIfNeeded(isVideoSurface: Bool) {
        cancelControlsAutoHide()
        guard isVideoSurface else { return }

        controlsAutoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showsVideoControls = false
            }
        }
    }

    private func cancelControlsAutoHide() {
        controlsAutoHideTask?.cancel()
        controlsAutoHideTask = nil
    }
}

// MARK: - Identity

private struct CallIdentitySection: View {
    let displayName: String
    let avatarURL: URL?
    let statusText: String
    let isConnecting: Bool
    let peerIsMuted: Bool
    let peerBatteryIsLow: Bool
    var peerVideoDisabled: Bool = false
    let isVideoSurface: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: SanchrSpacing.md) {
            ZStack {
                if isConnecting {
                    PulseRingView()
                }

                CallPeerAvatar(
                    displayName: displayName,
                    avatarURL: avatarURL,
                    size: 128,
                    isVideoSurface: isVideoSurface
                )
            }

            VStack(spacing: SanchrSpacing.xs) {
                Text(displayName)
                    .font(SanchrTypography.screenTitle)
                    .foregroundColor(primaryTextColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Text(statusText)
                    .font(SanchrTypography.body)
                    .foregroundColor(secondaryTextColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: statusText)
            }

            PeerStatusBadges(
                peerIsMuted: peerIsMuted,
                peerBatteryIsLow: peerBatteryIsLow,
                peerVideoDisabled: peerVideoDisabled,
                isVideoSurface: isVideoSurface
            )
        }
    }

    private var primaryTextColor: Color {
        isVideoSurface ? .white : Color.sanchrTextPrimary(colorScheme)
    }

    private var secondaryTextColor: Color {
        isVideoSurface ? .white.opacity(0.72) : Color.sanchrTextSecondary(colorScheme)
    }
}

private struct CallPeerAvatar: View {
    let displayName: String
    let avatarURL: URL?
    let size: CGFloat
    let isVideoSurface: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            fallbackAvatar

            if let avatarURL {
                KFImage(avatarURL)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(borderColor, lineWidth: 2)
        }
        .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
        .accessibilityHidden(true)
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(SanchrGradients.primary)

            Text(initials)
                .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    private var initials: String {
        let words = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
        return words.isEmpty ? "?" : words
    }

    private var borderColor: Color {
        isVideoSurface ? Color.white.opacity(0.24) : Color.sanchrAvatarBorder(colorScheme)
    }

    private var shadowColor: Color {
        isVideoSurface ? .black.opacity(0.35) : SanchrColors.primary.opacity(0.20)
    }
}

private struct PeerStatusBadges: View {
    let peerIsMuted: Bool
    let peerBatteryIsLow: Bool
    let peerVideoDisabled: Bool
    let isVideoSurface: Bool

    var body: some View {
        if peerIsMuted || peerBatteryIsLow || peerVideoDisabled {
            HStack(spacing: SanchrSpacing.xs) {
                if peerVideoDisabled {
                    PeerStatusBadge(
                        icon: "video.slash.fill",
                        text: "Camera off",
                        tint: isVideoSurface ? .white : SanchrColors.warning,
                        isVideoSurface: isVideoSurface
                    )
                }
                if peerIsMuted {
                    PeerStatusBadge(
                        icon: "mic.slash.fill",
                        text: "Muted",
                        tint: SanchrColors.warning,
                        isVideoSurface: isVideoSurface
                    )
                }
                if peerBatteryIsLow {
                    PeerStatusBadge(
                        icon: "battery.25",
                        text: "Low battery",
                        tint: SanchrColors.warning,
                        isVideoSurface: isVideoSurface
                    )
                }
            }
        }
    }
}

private struct PeerStatusBadge: View {
    let icon: String
    let text: String
    let tint: Color
    let isVideoSurface: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SanchrSpacing.xxs) {
            Image(systemName: icon)
                .font(SanchrTypography.captionSmall)
            Text(text)
                .font(SanchrTypography.captionSmall)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, SanchrSpacing.sm)
        .padding(.vertical, SanchrSpacing.xxs)
        .background(tint.opacity(isVideoSurface ? 0.22 : 0.14))
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
        .clipShape(Capsule())
    }

    private var foregroundColor: Color {
        isVideoSurface ? .white : Color.sanchrTextPrimary(colorScheme)
    }
}

// MARK: - Action Dock

private struct CallActionDock<Content: View>: View {
    let isVideoSurface: Bool
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(isVideoSurface: Bool, @ViewBuilder content: () -> Content) {
        self.isVideoSurface = isVideoSurface
        self.content = content()
    }

    var body: some View {
        SanchrGlassCluster(spacing: SanchrSpacing.sm) {
            content
                .padding(.horizontal, SanchrSpacing.xs)
                .padding(.vertical, SanchrSpacing.md)
                .frame(maxWidth: .infinity)
                .modifier(CallDockBackgroundModifier(
                    isVideoSurface: isVideoSurface,
                    colorScheme: colorScheme
                ))
        }
    }
}

private struct CallDockBackgroundModifier: ViewModifier {
    let isVideoSurface: Bool
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .sanchrGlass(
                    role: .viewerCard,
                    tint: isVideoSurface ? Color.black.opacity(0.18) : SanchrColors.primary.opacity(0.08)
                )
        } else {
            content
                .background(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: SanchrExportMetrics.largeRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: SanchrExportMetrics.largeRadius, style: .continuous))
        }
    }

    private var backgroundColor: Color {
        isVideoSurface ? Color.black.opacity(0.42) : Color.sanchrSurfaceElevated(colorScheme).opacity(0.94)
    }

    private var borderColor: Color {
        isVideoSurface ? Color.white.opacity(0.12) : Color.sanchrBorder(colorScheme)
    }
}

private struct CallControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    var isDisabled: Bool = false
    var isDestructive: Bool = false
    let isVideoSurface: Bool
    var accessibilityValue: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false

    var body: some View {
        Button(action: runAction) {
            VStack(spacing: SanchrSpacing.xxs) {
                iconView

                Text(label)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? (isDestructive ? "" : (isActive ? "On" : "Off")))
    }

    private var iconView: some View {
        ZStack {
            iconBackground

            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(iconColor)
        }
        .frame(width: 52, height: 52)
        .scaleEffect(isPressed ? 0.92 : 1)
    }

    @ViewBuilder
    private var iconBackground: some View {
        if isDestructive {
            Circle()
                .fill(SanchrColors.error)
                .shadow(color: SanchrColors.error.opacity(0.35), radius: 10, x: 0, y: 5)
        } else if isActive {
            Circle()
                .fill(SanchrColors.primary)
                .shadow(color: SanchrColors.primary.opacity(0.28), radius: 10, x: 0, y: 5)
        } else {
            Circle()
                .fill(inactiveBackground)
                .overlay {
                    Circle()
                        .stroke(inactiveBorder, lineWidth: 1)
                }
        }
    }

    private var inactiveBackground: Color {
        isVideoSurface ? Color.white.opacity(0.14) : Color.sanchrSurface(colorScheme)
    }

    private var inactiveBorder: Color {
        isVideoSurface ? Color.white.opacity(0.14) : Color.sanchrBorder(colorScheme)
    }

    private var iconColor: Color {
        if isDestructive || isActive || isVideoSurface {
            return .white
        }
        return Color.sanchrTextPrimary(colorScheme)
    }

    private var labelColor: Color {
        if isDisabled {
            return isVideoSurface ? .white.opacity(0.42) : Color.sanchrTextTertiary(colorScheme)
        }
        return isVideoSurface ? .white.opacity(0.76) : Color.sanchrTextSecondary(colorScheme)
    }

    private func runAction() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.65)) {
            isPressed = true
        }
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation {
                isPressed = false
            }
        }
    }
}

private struct IncomingCallButton: View {
    let icon: String
    let label: String
    let tint: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: SanchrSpacing.xs) {
                ZStack {
                    Circle()
                        .fill(tint)
                        .shadow(color: tint.opacity(0.28), radius: 12, x: 0, y: 6)

                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 72, height: 72)

                Text(label)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct CallEncryptionBadgeModifier: ViewModifier {
    let isVideoSurface: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.sanchrGlass(
                role: .chip,
                tint: isVideoSurface ? Color.white.opacity(0.12) : SanchrColors.success.opacity(0.12)
            )
        } else {
            content
                .background(SanchrColors.encryptionBadge)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Pulse Ring Animation

private struct PulseRingView: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(SanchrColors.primary.opacity(0.30), lineWidth: 2)
                    .frame(width: 128, height: 128)
                    .scaleEffect(isPulsing ? 1.55 + CGFloat(index) * 0.14 : 1.0)
                    .opacity(isPulsing ? 0 : 0.62)
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
