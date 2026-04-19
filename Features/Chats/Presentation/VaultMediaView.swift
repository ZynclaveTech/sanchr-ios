import SanchrShared
import SwiftUI

// MARK: - VaultMediaView
// Extracted from ConversationInfoView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct VaultMediaView: View {
    let conversationId: String

    @Environment(DependencyContainer.self) private var container
    @State private var policy: ChatVaultPolicy
    @State private var isLoading: Bool = true

    init(conversationId: String) {
        self.conversationId = conversationId
        self._policy = State(initialValue: .defaults(for: conversationId))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Info banner
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrColors.primaryDark)
                        .padding(.top, 2)
                    Text(
                        "Vault media is encrypted at rest, can self-destruct after viewing, and is hidden during screen recording or mirroring. Screenshots can still trigger an alert."
                    )
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(SanchrExportColors.textSecondary)
                }
                .padding(16)
                .background(
                    LinearGradient(
                        colors: [
                            SanchrColors.primaryDark.opacity(0.05),
                            SanchrColors.primary.opacity(0.05),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                vaultToggle(
                    icon: "tray.and.arrow.down.fill",
                    title: "Auto-Vault Incoming",
                    subtitle: "Automatically protect received media in this chat",
                    isOn: Binding(
                        get: { policy.autoVaultIncoming },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: newValue,
                                viewOnceOutgoing: policy.viewOnceOutgoing,
                                screenshotProtection: policy.screenshotProtection
                            )
                            persist()
                        }
                    )
                )

                Rectangle().fill(SanchrExportColors.line).frame(height: 1).padding(.leading, 72)

                vaultToggle(
                    icon: "eye.fill",
                    title: "View Once",
                    subtitle: "Media you send disappears after the recipient views it",
                    isOn: Binding(
                        get: { policy.viewOnceOutgoing },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: policy.autoVaultIncoming,
                                viewOnceOutgoing: newValue,
                                screenshotProtection: policy.screenshotProtection
                            )
                            persist()
                        }
                    )
                )

                Rectangle().fill(SanchrExportColors.line).frame(height: 1).padding(.leading, 72)

                vaultToggle(
                    icon: "camera.metering.none",
                    title: "Capture Protection",
                    subtitle: "Hide vault media during screen recording or mirroring, and notify the other person if you take a screenshot",
                    isOn: Binding(
                        get: { policy.screenshotProtection },
                        set: { newValue in
                            policy = ChatVaultPolicy(
                                conversationId: conversationId,
                                autoVaultIncoming: policy.autoVaultIncoming,
                                viewOnceOutgoing: policy.viewOnceOutgoing,
                                screenshotProtection: newValue
                            )
                            persist()
                        }
                    )
                )
            }
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Vault Media")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await container.chatVaultPolicy.loadPolicy(conversationId: conversationId)
            policy = container.chatVaultPolicy.effectivePolicy(for: conversationId)
            isLoading = false
        }
    }

    private func persist() {
        Task {
            await container.chatVaultPolicy.setPolicy(policy)
        }
    }

    private func vaultToggle(icon: String, title: String, subtitle: String, isOn: Binding<Bool>)
        -> some View
    {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceSoft)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
    }
}
