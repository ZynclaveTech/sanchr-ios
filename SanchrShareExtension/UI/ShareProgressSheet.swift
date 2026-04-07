import SwiftUI
import SanchrShared

// MARK: - Driver protocol (filled in by T27)

/// Per-recipient state surfaced from the (yet-to-be-built) send
/// coordinator. The progress sheet only knows about this enum and the
/// `ShareSendDriving` protocol below; T27 will land the real
/// `ShareSendCoordinator` actor that conforms to it.
enum ShareRecipientState: Equatable {
    case pending
    case sending
    case success
    case failure(String)
}

/// Abstract sender used by `ShareProgressSheet` so the UI can ship and
/// be reviewed before T27 wires up the real `ShareSendCoordinator`.
/// `ShareSendCoordinator` will be an `actor` that conforms to this
/// protocol; the closure-based progress callback keeps the UI free of
/// any concrete coordinator type.
protocol ShareSendDriving: Sendable {
    func send(
        payload: SharePayload,
        caption: String?,
        recipients: [ShareChatSummary],
        progress: @Sendable @escaping (String, ShareRecipientState, Double) -> Void
    ) async
}

/// No-op driver used until T27 ships the real coordinator. Marks every
/// recipient as failed with an explanatory message so manual testing of
/// the sheet behaviour (Done button, retry affordance) still works.
struct ShareSendDriverPlaceholder: ShareSendDriving {
    func send(
        payload: SharePayload,
        caption: String?,
        recipients: [ShareChatSummary],
        progress: @Sendable @escaping (String, ShareRecipientState, Double) -> Void
    ) async {
        for recipient in recipients {
            progress(recipient.id, .sending, 0)
            try? await Task.sleep(nanoseconds: 250_000_000)
            progress(
                recipient.id,
                .failure("Send pipeline lands in the next task."),
                0
            )
        }
    }
}

// MARK: - View

/// Block-on-completion progress sheet shown while the send coordinator
/// dispatches the payload to every selected recipient. Renders a linear
/// overall progress bar, a per-recipient row list with state icons, and
/// a Done button that only enables after the run finishes.
///
/// The sheet swallows interactive dismissal so users can't accidentally
/// abandon a half-sent share by swiping down.
struct ShareProgressSheet: View {

    let payload: SharePayload
    let recipients: [ShareChatSummary]
    let caption: String?
    let onDone: () -> Void
    let onCancel: () -> Void

    /// Injected so T27 can provide the real coordinator without touching
    /// this file. Defaults to the placeholder so the sheet ships
    /// independently of the coordinator.
    var driver: ShareSendDriving = ShareSendDriverPlaceholder()

    @State private var states: [String: ShareRecipientState] = [:]
    @State private var overallProgress: Double = 0
    @State private var finished: Bool = false

    private var hasFailures: Bool {
        states.values.contains {
            if case .failure = $0 { return true } else { return false }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            header

            ProgressView(value: overallProgress)
                .progressViewStyle(.linear)
                .tint(SanchrColors.primary)
                .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(recipients) { recipient in
                        recipientRow(
                            recipient: recipient,
                            state: states[recipient.id] ?? .pending
                        )
                    }
                }
                .padding(.horizontal, 16)
            }

            footer
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .interactiveDismissDisabled(true)
        .task { await runSend() }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 4) {
            Text(finished ? finishedTitle : "Sending\u{2026}")
                .font(.title3.weight(.semibold))
            if let caption, !caption.isEmpty {
                Text("\u{201C}\(caption)\u{201D}")
                    .font(.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 8)
    }

    private var finishedTitle: String {
        if hasFailures {
            let failed = states.values.reduce(into: 0) { count, state in
                if case .failure = state { count += 1 }
            }
            return "Sent with \(failed) failure\(failed == 1 ? "" : "s")"
        } else {
            return "Sent"
        }
    }

    private func recipientRow(recipient: ShareChatSummary, state: ShareRecipientState) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(uiColor: .systemGray5))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(recipient.title.prefix(1)).uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundColor(SanchrExportColors.textSecondary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(recipient.title)
                    .font(.body)
                    .lineLimit(1)
                if case .failure(let reason) = state {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            stateIcon(for: state)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stateIcon(for state: ShareRecipientState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        case .sending:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(SanchrColors.success)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if finished, hasFailures {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
            Button(finished ? "Done" : "Sending\u{2026}", action: onDone)
                .buttonStyle(.borderedProminent)
                .tint(SanchrColors.primary)
                .disabled(!finished)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Driver wiring

    private func runSend() async {
        // Seed every recipient as pending so the row list renders before
        // the coordinator emits its first event.
        var seed: [String: ShareRecipientState] = [:]
        for recipient in recipients { seed[recipient.id] = .pending }
        states = seed

        await driver.send(
            payload: payload,
            caption: caption,
            recipients: recipients
        ) { id, state, overall in
            Task { @MainActor in
                self.states[id] = state
                self.overallProgress = overall
            }
        }

        await MainActor.run {
            // Recompute the overall bar from the final state map so the
            // bar reflects partial success even if the driver forgot to
            // emit a terminal `overall == 1.0` event.
            let total = max(recipients.count, 1)
            let done = states.values.reduce(into: 0) { count, state in
                switch state {
                case .success, .failure: count += 1
                case .pending, .sending: break
                }
            }
            self.overallProgress = Double(done) / Double(total)
            self.finished = true
        }
    }
}
