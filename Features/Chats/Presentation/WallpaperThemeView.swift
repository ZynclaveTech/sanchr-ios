import SanchrShared
import SwiftUI

// MARK: - WallpaperThemeView
// Extracted from ConversationInfoView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct WallpaperThemeView: View {
    let conversationId: String

    @Environment(DependencyContainer.self) private var container
    @State private var selectedWallpaperId: String = "default"
    @State private var darkMode: Bool = false
    @State private var hasOverride: Bool = false
    @State private var isLoading: Bool = true
    /// The wallpaper last chosen for each tone, keyed by `isDark`.
    ///
    /// Toggling Dark Mode changes the wallpaper when the current one does not
    /// match the new tone, and toggling back used to land on the first light
    /// wallpaper rather than the one the user had picked — an unrelated switch
    /// quietly destroying their choice, with no way to get it back.
    @State private var wallpaperByTone: [Bool: String] = [:]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                scopeBanner
                darkModeToggleRow
                wallpaperGrid
                if hasOverride {
                    resetToGlobalButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Wallpaper & Theme")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await container.chatAppearance.loadOverride(conversationId: conversationId)
            let appearance = container.chatAppearance.effectiveAppearance(for: conversationId)
            selectedWallpaperId = appearance.wallpaperId
            darkMode = (appearance.appearanceMode == .dark)
            hasOverride = appearance.isPerChatOverride
            isLoading = false
        }
    }

    @ViewBuilder
    private var scopeBanner: some View {
        let copy = hasOverride
            ? "Applied to this chat only — overrides global"
            : "Inheriting global appearance"
        Text(copy)
            .font(SanchrTypography.captionSmall)
            .foregroundColor(SanchrExportColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SanchrExportColors.surfaceSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var darkModeToggleRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceSoft)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: darkMode ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SanchrColors.primary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Dark Mode")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.medium)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Use dark theme for this chat only")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { darkMode },
                set: { newValue in
                    darkMode = newValue
                    autoSwitchWallpaperForMode(newValue)
                    Task { await applyOverride() }
                }
            ))
            .labelsHidden()
            .tint(.sanchrPrimary)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var wallpaperGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chat Wallpaper")
                .font(SanchrTypography.messageBubbleText)
                .fontWeight(.semibold)
                .foregroundColor(SanchrExportColors.textPrimary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                ForEach(WallpaperPainter.allWallpapers) { wp in
                    WallpaperPainter.background(for: wp.id)
                        .aspectRatio(0.7, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if selectedWallpaperId == wp.id {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SanchrColors.primary, lineWidth: 3)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(SanchrColors.primary)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedWallpaperId = wp.id
                                darkMode = wp.isDark
                            }
                            Task { await applyOverride() }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var resetToGlobalButton: some View {
        Button {
            Task { await resetToGlobal() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                Text("Reset to Global")
                    .font(SanchrTypography.messageBubbleText)
                    .fontWeight(.semibold)
            }
            .foregroundColor(SanchrColors.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(SanchrColors.primary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutations

    private func applyOverride() async {
        await container.chatAppearance.setOverride(
            conversationId: conversationId,
            wallpaperId: selectedWallpaperId,
            appearanceMode: darkMode ? .dark : .light
        )
        hasOverride = true
    }

    private func resetToGlobal() async {
        await container.chatAppearance.setOverride(
            conversationId: conversationId,
            wallpaperId: nil,
            appearanceMode: nil
        )
        let appearance = container.chatAppearance.effectiveAppearance(for: conversationId)
        selectedWallpaperId = appearance.wallpaperId
        darkMode = (appearance.appearanceMode == .dark)
        // Read back rather than assumed false: the banner says whether this
        // chat overrides the global choice, and asserting it does not — when
        // the store may disagree — makes the banner lie.
        hasOverride = appearance.isPerChatOverride
    }

    /// When the user toggles dark mode, move to a wallpaper of the matching
    /// tone — but to the one they last chose for that tone when there is one,
    /// so toggling twice returns them to where they were instead of to the
    /// first wallpaper in the registry.
    private func autoSwitchWallpaperForMode(_ isDark: Bool) {
        let currentWp = WallpaperPainter.wallpaper(for: selectedWallpaperId)
        guard currentWp.isDark != isDark else { return }
        wallpaperByTone[currentWp.isDark] = selectedWallpaperId
        if let remembered = wallpaperByTone[isDark],
           WallpaperPainter.allWallpapers.contains(where: { $0.id == remembered && $0.isDark == isDark })
        {
            selectedWallpaperId = remembered
            return
        }
        if let first = WallpaperPainter.allWallpapers.first(where: { $0.isDark == isDark }) {
            selectedWallpaperId = first.id
        }
    }
}
