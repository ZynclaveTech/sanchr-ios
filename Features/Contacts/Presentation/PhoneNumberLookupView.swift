import SwiftUI
import SanchrShared

struct PhoneNumberLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phoneNumber = ""

    private var isPhoneValid: Bool {
        phoneNumber.filter(\.isNumber).count >= 8
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: SanchrSpacing.xl) {
                VStack(spacing: SanchrSpacing.sm) {
                    Image(systemName: "phone.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(SanchrGradients.primaryDark)
                        .frame(width: 80, height: 80)
                        .background(SanchrColors.primary.opacity(0.12))
                        .clipShape(Circle())

                    Text("Find by Phone Number")
                        .font(SanchrTypography.cardTitle)
                        .foregroundColor(SanchrExportColors.textPrimary)
                }
                .padding(.top, SanchrSpacing.xl)

                VStack(spacing: SanchrSpacing.xs) {
                    TextField("Phone number", text: $phoneNumber)
                        .font(SanchrTypography.bodyLarge)
                        .keyboardType(.phonePad)
                        .padding(SanchrSpacing.md)
                        .background(SanchrExportColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.input))
                        .overlay(
                            RoundedRectangle(cornerRadius: SanchrRadius.input)
                                .stroke(SanchrExportColors.line, lineWidth: 1)
                        )

                    Text("Enter the full phone number with country code")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

                Button {
                    SanchrLogger.contacts.info("Phone lookup requested for number (redacted)")
                    // Future: OPRF single-number lookup
                } label: {
                    SanchrGradientButtonLabel(title: "Find Contact", systemName: "magnifyingglass")
                }
                .disabled(!isPhoneValid)
                .opacity(isPhoneValid ? 1.0 : 0.5)
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

                // Informational message
                VStack(spacing: SanchrSpacing.xs) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(SanchrColors.info)

                    Text("Contact discovery runs automatically when you sync your contacts. Pull to refresh on the Contacts tab.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(SanchrSpacing.md)
                .background(SanchrColors.info.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

                Spacer()
            }
            .sanchrScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
