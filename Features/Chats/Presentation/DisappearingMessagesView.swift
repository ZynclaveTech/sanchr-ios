import SanchrShared
import SwiftUI

// MARK: - DisappearingMessagesView
// Extracted from ConversationInfoView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct DisappearingMessagesView: View {
    let conversationId: String

    @State private var selectedDuration: Int = 0

    private let options: [(String, String, Int)] = [
        ("Off", "Messages won't be deleted", 0),
        ("5 minutes", "For sensitive conversations", 300),
        ("1 hour", "Short-lived messages", 3600),
        ("24 hours", "Daily cleanup", 86400),
        ("7 days", "Weekly cleanup", 604800),
        ("30 days", "Monthly cleanup", 2_592_000),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Info banner
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(SanchrColors.primary)
                        .padding(.top, 2)
                    Text(
                        "When enabled, new messages will disappear after the selected time. This applies to both sides of the conversation."
                    )
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrExportColors.textSecondary)
                }
                .padding(16)
                .background(SanchrColors.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                // Timer options
                ForEach(0..<options.count, id: \.self) { index in
                    let option = options[index]
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDuration = option.2
                        }
                        DisappearingTimerStore.setDuration(
                            conversationId: conversationId,
                            secs: Int64(option.2)
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(
                                    selectedDuration == option.2
                                        ? SanchrColors.primary.opacity(0.1)
                                        : SanchrExportColors.surfaceSoft
                                )
                                .frame(width: 40, height: 40)
                                .overlay {
                                    Image(systemName: option.2 == 0 ? "xmark" : "clock.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(
                                            selectedDuration == option.2
                                                ? SanchrColors.primary
                                                : SanchrExportColors.textSecondary)
                                }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.0)
                                    .font(SanchrTypography.messageBubbleText)
                                    .fontWeight(.medium)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                Text(option.1)
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                            }

                            Spacer()

                            if selectedDuration == option.2 {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(SanchrColors.primary)
                            } else {
                                Circle()
                                    .stroke(SanchrExportColors.line, lineWidth: 2)
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)

                    if index < options.count - 1 {
                        Rectangle()
                            .fill(SanchrExportColors.line)
                            .frame(height: 1)
                            .padding(.leading, 72)
                    }
                }
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Disappearing Messages")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedDuration = Int(
                DisappearingTimerStore.getDuration(conversationId: conversationId)
            )
        }
    }
}
