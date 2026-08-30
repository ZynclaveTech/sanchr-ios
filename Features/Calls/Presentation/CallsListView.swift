import Kingfisher
import SwiftUI
import SanchrShared

struct CallsListView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = CallsViewModel()
    @State private var showNewCallPicker = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            mainContent
            newCallButton
        }
        .navigationBarHidden(true)
        .sanchrInteractivePopEnabled()
        .background(SanchrExportColors.background)
        .sheet(isPresented: $showNewCallPicker) {
            NewCallContactPicker(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .refreshable {
            // `.refreshable` runs in a SwiftUI-managed Task that gets cancelled when
            // the view re-renders (e.g. `isLoading` flips). Fire an unstructured Task
            // so the gRPC call isn't cancelled mid-flight, and use a CheckedContinuation
            // to hold the spinner open until the load actually completes.
            await withCheckedContinuation { continuation in
                Task {
                    // showLoadingIndicator: false — the native pull-to-refresh spinner
                    // is already visible; toggling isLoading while the refresh control
                    // is active causes "not idle" UIKit warnings.
                    await viewModel.loadCallHistory(localDatabase: container.localDatabase, showLoadingIndicator: false)
                    continuation.resume()
                }
            }
        }
        .task {
            viewModel.configure(
                callManager: container.callManager,
                getCallHistoryUseCase: container.getCallHistoryUseCase,
                startCallUseCase: container.startCallUseCase
            )
            // Use an unstructured Task so that SwiftUI .task cancellation
            // (triggered by view re-renders during startup) does not propagate
            // to the gRPC call. The server responds in ~5 ms; the structured
            // task was being cancelled before the response arrived back on iOS,
            // producing a spurious GRPCStatus.cancelled on every app open.
            Task { await viewModel.loadCallHistory(localDatabase: container.localDatabase) }
        }
        .onChange(of: container.callManager.callState) { _, newState in
            if newState != .idle {
                showNewCallPicker = false
            }
        }
        // A call answered from the lock screen can fail for a reason the user
        // can fix, with the app not foreground and nowhere to say so at the
        // time. Deliver it here instead, through the banner this screen
        // already has.
        .task(id: container.callManager.lastCallError) {
            guard let error = container.callManager.lastCallError else { return }
            viewModel.errorMessage = error
            container.callManager.lastCallError = nil
        }
    }

    private var mainContent: some View {
        Group {
            if viewModel.callHistory.isEmpty && viewModel.isLoading {
                loadingState
            } else {
                callList
            }
        }
        .background(SanchrExportColors.background)
    }

    private var loadingState: some View {
        VStack(spacing: 0) {
            customHeader
            Spacer()
            ProgressView()
                .tint(.sanchrPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SanchrExportColors.background)
    }

    private var callList: some View {
        List {
            Section {
                customHeader
                    .listRowInsets(EdgeInsets())

                searchBar
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.top, 2)
                    .listRowInsets(EdgeInsets())

                filterBar
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .listRowInsets(EdgeInsets())

                if !viewModel.callHistory.isEmpty {
                    summaryStrip
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                        .padding(.bottom, 8)
                        .listRowInsets(EdgeInsets())
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(SanchrExportColors.background)

            if viewModel.groupedCallHistory.isEmpty {
                Section {
                    emptyState
                        .listRowInsets(EdgeInsets())
                }
                .listRowSeparator(.hidden)
                .listRowBackground(SanchrExportColors.background)
            } else {
                ForEach(viewModel.groupedCallHistory) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            CallHistoryRow(entry: entry) {
                                Task { await redial(entry) }
                            }
                            .listRowInsets(EdgeInsets())
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteEntry(entry) }
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await redial(entry) }
                                } label: {
                                    Label("Call back", systemImage: entry.isVideo ? "video.fill" : "phone.fill")
                                }
                                .tint(.sanchrPrimary)
                            }
                        }
                    } header: {
                        sectionHeaderLabel(section.title)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(SanchrExportColors.background)
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    errorBanner(error)
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                        .listRowInsets(EdgeInsets())
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                Color.clear
                    .frame(height: 92)
                    .listRowInsets(EdgeInsets())
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(SanchrExportColors.background)
        .scrollDismissesKeyboard(.interactively)
    }

    private var customHeader: some View {
        SanchrBrandHeader(title: "Calls") {
            SanchrGlassCluster(spacing: 12) {
                HStack(spacing: 10) {
                    SanchrIconButton(
                        systemName: "arrow.clockwise",
                        foreground: SanchrExportColors.textSecondary,
                        background: SanchrExportColors.surface
                    ) {
                        Task { await viewModel.loadCallHistory(localDatabase: container.localDatabase) }
                    }
                    .accessibilityLabel("Refresh calls")

                    Menu {
                        Button {
                            showNewCallPicker = true
                        } label: {
                            Label("New Call", systemImage: "phone.plus")
                        }

                        Button(role: .destructive) {
                            Task { await viewModel.clearHistory() }
                        } label: {
                            Label("Clear Local History", systemImage: "trash")
                        }
                    } label: {
                        Group {
                            if #available(iOS 26.0, *) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .frame(width: 40, height: 40)
                                    .sanchrGlass(role: .toolbarButton, interactive: true)
                            } else {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                    .frame(width: 40, height: 40)
                            }
                        }
                    }
                    .accessibilityLabel("Calls menu")
                }
            }
        }
    }

    private var searchBar: some View {
        SanchrSearchField(placeholder: "Search calls...", text: $viewModel.searchText) {
            Button {
                if viewModel.searchText.isEmpty {
                    viewModel.selectedFilter = .missed
                } else {
                    viewModel.searchText = ""
                }
            } label: {
                Image(systemName: viewModel.searchText.isEmpty ? "phone.badge.waveform" : "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.searchText.isEmpty ? "Show missed calls" : "Clear search")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SanchrSpacing.filterTabGap) {
                ForEach(CallFilter.allCases) { filter in
                    SanchrFilterChip(
                        title: filter.rawValue,
                        isSelected: viewModel.selectedFilter == filter
                    ) {
                        // Matches the chats list: no implicit animation, which
                        // otherwise animates the whole list swap as a flicker.
                        viewModel.selectedFilter = filter
                    }
                }
            }
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: SanchrSpacing.sm) {
            CallMetricChip(
                title: "\(viewModel.callHistory.count)",
                subtitle: "Total",
                systemImage: "phone.connection.fill",
                tint: SanchrColors.primary
            )

            CallMetricChip(
                title: "\(viewModel.missedCount)",
                subtitle: "Missed",
                systemImage: "phone.down.fill",
                tint: viewModel.missedCount > 0 ? SanchrColors.error : SanchrColors.success
            )
        }
    }

    private var newCallButton: some View {
        Button {
            showNewCallPicker = true
        } label: {
            Group {
                if #available(iOS 26.0, *) {
                    Image(systemName: "phone.fill.badge.plus")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: SanchrSpacing.fabSize, height: SanchrSpacing.fabSize)
                        .sanchrGlass(
                            role: .floatingAction,
                            interactive: true,
                            prominence: .prominent,
                            tint: SanchrColors.primary
                        )
                } else {
                    Image(systemName: "phone.fill.badge.plus")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: SanchrSpacing.fabSize, height: SanchrSpacing.fabSize)
                        .background(SanchrGradients.primary)
                        .clipShape(Circle())
                        .shadow(color: SanchrColors.primary.opacity(0.28), radius: 24, x: 0, y: 14)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.trailing, SanchrExportMetrics.screenHorizontal)
        .padding(.bottom, SanchrSpacing.lg)
        .accessibilityLabel("Start a new call")
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: SanchrSpacing.xxxl)

            VStack(spacing: 18) {
                Circle()
                    .fill(SanchrColors.primary.opacity(0.12))
                    .frame(width: 104, height: 104)
                    .overlay {
                        Image(systemName: viewModel.callHistory.isEmpty ? "phone.fill" : "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(SanchrGradients.primaryDark)
                    }

                Text(viewModel.callHistory.isEmpty ? "No calls yet" : "No matching calls")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text(viewModel.callHistory.isEmpty
                    ? "Your encrypted call history will appear here."
                    : "Try another search or filter.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

            Spacer(minLength: SanchrSpacing.xxxl)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .background(SanchrExportColors.background)
    }

    private func sectionHeaderLabel(_ title: String) -> some View {
        SanchrSectionEyebrow(title: title)
            .textCase(nil)
            .listRowInsets(EdgeInsets())
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: SanchrSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrColors.error)
            Text(message)
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrColors.error)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(SanchrSpacing.sm)
        .background(SanchrColors.error.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: SanchrSpacing.sm, style: .continuous))
    }

    @discardableResult
    private func redial(_ entry: CallHistoryEntry) async -> Bool {
        if entry.isVideo {
            return await viewModel.startVideoCall(
                contactId: entry.contactId,
                name: entry.displayName
            )
        } else {
            return await viewModel.startVoiceCall(
                contactId: entry.contactId,
                name: entry.displayName
            )
        }
    }
}

private struct CallMetricChip: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: SanchrSpacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SanchrSpacing.sm)
        .padding(.vertical, SanchrSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: SanchrSpacing.sm, style: .continuous))
    }
}

private struct CallHistoryRow: View {
    let entry: CallHistoryEntry
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CallAvatarView(
                displayName: entry.displayName,
                avatarURL: entry.avatarURL,
                status: nil,
                badgeSystemImage: entry.isVideo ? "video.fill" : "phone.fill"
            )

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: SanchrSpacing.xs) {
                    Text(entry.displayName)
                        .font(SanchrTypography.conversationName)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .lineLimit(1)

                    if entry.isVideo {
                        Image(systemName: "video.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(SanchrColors.accent)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(statusColor)

                    Text(statusText)
                        .font(SanchrTypography.conversationPreviewBold)
                        .foregroundColor(statusColor)

                    if entry.duration > 0 {
                        Text(durationText)
                            .font(SanchrTypography.conversationPreview)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                }

                Text(relativeTimestamp)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: SanchrSpacing.sm)

            Button(action: action) {
                Image(systemName: entry.isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(SanchrColors.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Call \(entry.displayName)")
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var statusText: String {
        switch entry.type {
        case .incoming:
            return "Incoming"
        case .outgoing:
            return "Outgoing"
        case .missed:
            return "Missed"
        }
    }

    private var statusIcon: String {
        switch entry.type {
        case .incoming:
            return "arrow.down.left.circle"
        case .outgoing:
            return "arrow.up.right.circle"
        case .missed:
            return "phone.down.circle"
        }
    }

    private var statusColor: Color {
        switch entry.type {
        case .incoming:
            return SanchrColors.success
        case .outgoing:
            return SanchrColors.primary
        case .missed:
            return SanchrColors.error
        }
    }

    private var durationText: String {
        let totalSeconds = Int(entry.duration.rounded())
        guard totalSeconds >= 60 else { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }

    private var relativeTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(entry.timestamp) {
            return "Today, \(entry.timestamp.chatTimestamp)"
        }
        if calendar.isDateInYesterday(entry.timestamp) {
            return "Yesterday, \(entry.timestamp.chatTimestamp)"
        }
        return entry.timestamp.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct NewCallContactPicker: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: CallsViewModel

    var body: some View {
        VStack(spacing: 0) {
            SanchrCenteredHeader(title: "New Call") {
                SanchrIconButton(systemName: "xmark", action: { dismiss() })
                    .accessibilityLabel("Close")
            } trailing: {
                Color.clear
            }

            searchBar
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                .padding(.top, SanchrSpacing.sm)
                .padding(.bottom, SanchrSpacing.xs)

            if let message = viewModel.newCallErrorMessage {
                pickerErrorBanner(message)
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.bottom, SanchrSpacing.xs)
            }

            pickerContent
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .task {
            await viewModel.loadNewCallContacts(
                contactRepository: container.contactRepository,
                localDatabase: container.localDatabase
            )
        }
        .onChange(of: container.callManager.callState) { _, newState in
            if newState != .idle {
                dismiss()
            }
        }
    }

    private var searchBar: some View {
        SanchrSearchField(placeholder: "Search contacts...", text: $viewModel.contactSearchText) {
            if !viewModel.contactSearchText.isEmpty {
                Button {
                    viewModel.contactSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear contact search")
            }
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        if viewModel.newCallContacts.isEmpty && viewModel.isLoadingContacts {
            Spacer()
            ProgressView()
                .tint(.sanchrPrimary)
            Spacer()
        } else if viewModel.filteredNewCallContacts.isEmpty {
            Spacer()
            VStack(spacing: SanchrSpacing.sm) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
                Text(viewModel.newCallContacts.isEmpty ? "No contacts yet" : "No matching contacts")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Synced Sanchr contacts will appear here.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            Spacer()
        } else {
            List {
                ForEach(viewModel.filteredNewCallContacts) { contact in
                    NewCallContactRow(
                        isIdentityVerified: container.signalProtocol
                            .isIdentityVerified(userId: contact.id),
                        contact: contact,
                        startVoiceCall: {
                            Task {
                                await viewModel.startVoiceCall(
                                    contactId: contact.id,
                                    name: callDisplayName(for: contact)
                                )
                            }
                        },
                        startVideoCall: {
                            Task {
                                await viewModel.startVideoCall(
                                    contactId: contact.id,
                                    name: callDisplayName(for: contact)
                                )
                            }
                        },
                        showsVideoCall: AppConfiguration.current.isVideoCallEnabled
                    )
                    .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(SanchrExportColors.background)
        }
    }

    private func pickerErrorBanner(_ message: String) -> some View {
        HStack(spacing: SanchrSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrColors.error)
            Text(message)
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrColors.error)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(SanchrSpacing.sm)
        .background(SanchrColors.error.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: SanchrSpacing.sm, style: .continuous))
    }

    private func callDisplayName(for contact: User) -> String {
        let name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, UUID(uuidString: name) == nil {
            return name
        }
        let phone = contact.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return phone.isEmpty ? "Unknown Caller" : phone
    }
}

private struct NewCallContactRow: View {
    /// Whether this person's identity key has been verified — not whether they
    /// have an account. See `User.isVerified`.
    let isIdentityVerified: Bool
    let contact: User
    let startVoiceCall: () -> Void
    let startVideoCall: () -> Void
    /// When `false`, the "Start video call" button is hidden.
    /// Mirrors `AppConfiguration.isVideoCallEnabled` — callers should pass
    /// `AppConfiguration.current.isVideoCallEnabled` so the CTA disappears
    /// in builds where video calling is disabled.
    var showsVideoCall: Bool = true

    var body: some View {
        HStack(spacing: SanchrSpacing.sm) {
            CallAvatarView(
                displayName: contact.displayName,
                avatarURL: contact.avatarURL,
                status: contact.status,
                badgeSystemImage: isIdentityVerified ? "shield.fill" : nil
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(contact.displayName)
                        .font(SanchrTypography.conversationName)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .lineLimit(1)

                    if isIdentityVerified {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(SanchrColors.accent)
                    }
                }

                Text(subtitle)
                    .font(SanchrTypography.conversationPreview)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: SanchrSpacing.xs)

            HStack(spacing: SanchrSpacing.xs) {
                CallPickerActionButton(
                    systemImage: "phone.fill",
                    accessibilityLabel: "Start voice call with \(contact.displayName)",
                    action: startVoiceCall
                )

                if showsVideoCall {
                    CallPickerActionButton(
                        systemImage: "video.fill",
                        accessibilityLabel: "Start video call with \(contact.displayName)",
                        action: startVideoCall
                    )
                }
            }
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        if let bio = contact.bio, !bio.isEmpty {
            return bio
        }
        if !contact.phoneNumber.isEmpty {
            return contact.phoneNumber
        }
        return contact.status == .online ? "Online" : "Sanchr contact"
    }
}

private struct CallPickerActionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(SanchrColors.primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct CallAvatarView: View {
    let displayName: String
    let avatarURL: URL?
    let status: User.Status?
    let badgeSystemImage: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let avatarURL {
                    KFImage(avatarURL)
                        .resizable()
                        .placeholder { avatarPlaceholder }
                        .fade(duration: 0.2)
                        .scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
            .frame(width: SanchrSpacing.chatAvatarSize, height: SanchrSpacing.chatAvatarSize)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(SanchrExportColors.background, lineWidth: 2)
            }

            if let badgeSystemImage {
                Circle()
                    .fill(SanchrColors.accent)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: badgeSystemImage)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .offset(x: 1, y: 1)
            } else if status == .online {
                Circle()
                    .fill(SanchrColors.statusOnline)
                    .frame(width: SanchrSpacing.statusIndicatorSize, height: SanchrSpacing.statusIndicatorSize)
                    .overlay {
                        Circle()
                            .stroke(SanchrExportColors.background, lineWidth: SanchrSpacing.statusIndicatorBorder)
                    }
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: SanchrSpacing.chatAvatarSize, height: SanchrSpacing.chatAvatarSize)
        .accessibilityHidden(true)
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(SanchrColors.primary.opacity(0.14))
            .overlay {
                Text(initials)
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.sanchrPrimary)
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
}
