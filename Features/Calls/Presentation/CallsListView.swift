import SwiftUI
import SanchrShared

struct CallsListView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = CallsViewModel()
    @State private var selectedFilter: CallFilter = .all

    enum CallFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case missed = "Missed"

        var id: String { rawValue }
    }

    private var filteredCallHistory: [CallHistoryEntry] {
        switch selectedFilter {
        case .all:
            return viewModel.callHistory
        case .missed:
            return viewModel.callHistory.filter { $0.type == .missed }
        }
    }

    var body: some View {
        Group {
            if viewModel.callHistory.isEmpty && viewModel.isLoading {
                loadingState
            } else if viewModel.callHistory.isEmpty {
                emptyState
            } else {
                callList
            }
        }
        .navigationBarHidden(true)
        .sanchrInteractivePopEnabled()
        .task {
            viewModel.configure(
                callManager: container.callManager,
                getCallHistoryUseCase: container.getCallHistoryUseCase,
                startCallUseCase: container.startCallUseCase
            )
            await viewModel.loadCallHistory()
        }
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
        ZStack(alignment: .bottomTrailing) {
            List {
                Section {
                    customHeader
                        .listRowInsets(EdgeInsets())

                    filterTabs
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        .listRowInsets(EdgeInsets())
                }
                .listRowSeparator(.hidden)
                .listRowBackground(SanchrExportColors.background)

                Section {
                    ForEach(filteredCallHistory) { entry in
                        CallHistoryRow(entry: entry) {
                            Task {
                                if entry.isVideo {
                                    await viewModel.startVideoCall(
                                        contactId: entry.contactId,
                                        name: entry.contactName
                                    )
                                } else {
                                    await viewModel.startVoiceCall(
                                        contactId: entry.contactId,
                                        name: entry.contactName
                                    )
                                }
                            }
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(SanchrExportColors.background)

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrError)
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

            helpButton
        }
        .background(SanchrExportColors.background)
    }

    private var customHeader: some View {
        HStack {
            Text("Calls")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(SanchrExportColors.textPrimary)

            Spacer()

            SanchrIconButton(systemName: "magnifyingglass") {}
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.top, SanchrExportMetrics.rootTop)
        .padding(.bottom, 8)
        .background(SanchrExportColors.background)
    }

    private var filterTabs: some View {
        HStack(spacing: 10) {
            ForEach(CallFilter.allCases) { filter in
                SanchrFilterChip(title: filter.rawValue, isSelected: selectedFilter == filter) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedFilter = filter
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var helpButton: some View {
        Button {} label: {
            Image(systemName: "questionmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(
                        colors: [SanchrColors.primary, SanchrColors.primaryDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .shadow(color: SanchrColors.primary.opacity(0.28), radius: 24, x: 0, y: 14)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            customHeader

            Spacer()

            VStack(spacing: 18) {
                Circle()
                    .fill(SanchrColors.primary.opacity(0.12))
                    .frame(width: 104, height: 104)
                    .overlay {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(SanchrGradients.primaryDark)
                    }

                Text("No calls yet")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text("Your encrypted call history will appear here.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SanchrExportColors.background)
    }
}

struct CallHistoryRow: View {
    let entry: CallHistoryEntry
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.contactName)
                    .font(SanchrTypography.conversationName)
                    .foregroundColor(SanchrExportColors.textPrimary)

                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(statusColor)

                    Text(statusText)
                        .font(SanchrTypography.conversationPreviewBold)
                        .foregroundColor(statusColor)

                    Circle()
                        .fill(Color(hex: 0xD1D5DB))
                        .frame(width: 4, height: 4)

                    Text(relativeTimestamp)
                        .font(SanchrTypography.conversationPreview)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
            }

            Spacer()

            Button(action: action) {
                Image(systemName: entry.isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(SanchrColors.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.vertical, 12)
    }

    private var avatar: some View {
        Circle()
            .fill(Color.sanchrPrimary.opacity(0.14))
            .frame(width: 56, height: 56)
            .overlay {
                Text(entry.contactName.prefix(1).uppercased())
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.sanchrPrimary)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(SanchrColors.accent)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .offset(x: 1, y: 1)
            }
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
            return Color(hex: 0x10B981)
        case .outgoing:
            return Color(hex: 0x22C55E)
        case .missed:
            return SanchrColors.error
        }
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
