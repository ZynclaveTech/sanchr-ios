import SwiftUI
import SanchrShared

struct AddContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DependencyContainer.self) private var container
    @Environment(AppRouter.self) private var router

    @State private var showQRScanner = false
    @State private var showPhoneLookup = false
    @State private var qrState: QRHandleState = .idle

    private enum QRHandleState {
        case idle
        case opening       // startDirectConversation in-flight
        case error(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: SanchrSpacing.lg) {
                Text("Add a Contact")
                    .font(SanchrTypography.sectionHeader)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .padding(.top, SanchrSpacing.xl)

                VStack(spacing: SanchrSpacing.sm) {
                    actionCard(
                        icon: "qrcode.viewfinder",
                        title: "Scan QR Code",
                        subtitle: "Point your camera at a Sanchr QR code"
                    ) {
                        showQRScanner = true
                    }

                    actionCard(
                        icon: "phone.badge.plus",
                        title: "Enter Phone Number",
                        subtitle: "Find someone by their phone number"
                    ) {
                        showPhoneLookup = true
                    }
                }
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

                // QR handling feedback
                switch qrState {
                case .idle:
                    EmptyView()
                case .opening:
                    HStack(spacing: SanchrSpacing.sm) {
                        ProgressView().tint(.sanchrPrimary)
                        Text("Opening conversation…")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .padding(.top, SanchrSpacing.xs)
                case .error(let message):
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
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.top, SanchrSpacing.xs)
                }

                Spacer()
            }
            .sanchrScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showQRScanner) {
                QRScannerView { scannedURL in
                    showQRScanner = false
                    Task { await handleScannedURL(scannedURL) }
                }
            }
            .sheet(isPresented: $showPhoneLookup) {
                PhoneNumberLookupView()
            }
        }
    }

    // MARK: - QR URL handling

    /// Reads the scanned profile link, opens or creates a direct conversation,
    /// then navigates to it and dismisses the sheet.
    private func handleScannedURL(_ urlString: String) async {
        guard let userId = ProfileLink.userId(from: urlString) else {
            SanchrLogger.contacts.warning("QR scan: not a profile link")
            qrState = .error("Unrecognised QR code. Make sure you're scanning a Sanchr contact code.")
            return
        }

        qrState = .opening

        do {
            let conversationId = try await container.messageRepository.startDirectConversation(peerUserId: userId)
            dismiss()
            // Brief pause so the sheet finishes dismissing before navigation fires
            try? await Task.sleep(nanoseconds: 300_000_000)
            router.deepLinkToConversation(conversationId: conversationId)
        } catch {
            qrState = .error(error.localizedDescription)
            SanchrLogger.contacts.error("QR scan: failed to open conversation – \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Action Card

    private func actionCard(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: SanchrSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(SanchrColors.primary)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: SanchrSpacing.xxs) {
                    Text(title)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)

                    Text(subtitle)
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
            .padding(SanchrSpacing.md)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
        }
        .buttonStyle(.plain)
    }
}
