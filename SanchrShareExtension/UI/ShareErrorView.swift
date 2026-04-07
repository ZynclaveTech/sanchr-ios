import SwiftUI
import SanchrShared

/// Terminal error screen shown when the share extension cannot continue —
/// migration not finished, payload too large, unsupported type, or any
/// loader failure. The single "Close" button cancels the extension request.
struct ShareErrorView: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(SanchrColors.primary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Close", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(SanchrColors.primary)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
