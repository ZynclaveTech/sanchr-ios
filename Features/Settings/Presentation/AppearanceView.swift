import SwiftUI

/// Theme and appearance settings screen.
/// Matches Figma: appearance-screen.
struct AppearanceView: View {
    @Environment(\.sanchrTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section("Theme") {
                ForEach(SanchrTheme.Mode.allCases) { mode in
                    HStack {
                        Text(mode.displayName)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                        if theme.mode == mode {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { theme.mode = mode }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Chat") {
                // TODO: Chat bubble style, font size, wallpaper
                Toggle("Large Text", isOn: .constant(false))
                    .tint(.sanchrPrimary)
                Toggle("Reduce Animations", isOn: .constant(false))
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
