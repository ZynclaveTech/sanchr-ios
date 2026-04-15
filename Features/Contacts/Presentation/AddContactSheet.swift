import SwiftUI
import SanchrShared

struct AddContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showQRScanner = false
    @State private var showPhoneLookup = false

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
                    SanchrLogger.contacts.info("Scanned QR URL: \(scannedURL, privacy: .public)")
                    // TODO: Handle deep link navigation from scanned URL
                }
            }
            .sheet(isPresented: $showPhoneLookup) {
                PhoneNumberLookupView()
            }
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
