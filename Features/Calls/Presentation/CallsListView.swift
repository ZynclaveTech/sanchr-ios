import SwiftUI

/// Call history list screen.
/// Matches Figma: calls-screen.
struct CallsListView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = CallsViewModel()

    var body: some View {
        Group {
            if viewModel.callHistory.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                List(viewModel.callHistory) { entry in
                    CallHistoryRow(
                        entry: entry,
                        colorScheme: colorScheme
                    ) {
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
                        .listRowBackground(Color.sanchrSurface(colorScheme))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Calls")
        .task {
            viewModel.configure(
                callManager: container.callManager,
                getCallHistoryUseCase: container.getCallHistoryUseCase,
                startCallUseCase: container.startCallUseCase
            )
            await viewModel.loadCallHistory()
        }
    }

    private var emptyState: some View {
        VStack(spacing: SanchrSpacing.md) {
            Image(systemName: "phone.circle")
                .font(.system(size: 64))
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            Text("No calls yet")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
            Text("Your encrypted call history will appear here")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sanchrScreenBackground()
    }
}

// MARK: - Call History Row

struct CallHistoryRow: View {
    let entry: CallHistoryEntry
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        HStack(spacing: SanchrSpacing.sm) {
            // Avatar
            Circle()
                .fill(Color.sanchrPrimary.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(entry.contactName.prefix(1).uppercased())
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.sanchrPrimary)
                }

            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                Text(entry.contactName)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(
                        entry.type == .missed
                            ? .sanchrError
                            : Color.sanchrTextPrimary(colorScheme)
                    )

                HStack(spacing: SanchrSpacing.xxs) {
                    Image(systemName: entry.directionIcon)
                        .font(.caption2)
                        .foregroundColor(
                            entry.type == .missed
                                ? .sanchrError : Color.sanchrTextTertiary(colorScheme))
                    Text(entry.timestamp.chatTimestamp)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }

            Spacer()

            Button {
                action()
            } label: {
                Image(systemName: entry.isVideo ? "video.fill" : "phone.fill")
                    .foregroundColor(.sanchrPrimary)
            }
        }
        .padding(.vertical, SanchrSpacing.xxs)
    }
}
