import SwiftUI

/// The one line a settings screen shows when a load or save fails.
///
/// Renders nothing for `nil`, so a screen can place it unconditionally at
/// the end of its content stack.
struct SettingsErrorLabel: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(SanchrTypography.caption)
                .foregroundColor(.sanchrError)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Error: \(message)")
        }
    }
}
