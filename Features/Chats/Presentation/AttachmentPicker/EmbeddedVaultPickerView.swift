import SwiftUI
import SanchrShared

/// Embedded vault picker presented from the attachment picker sheet.
///
/// Loads vault items via `VaultSource` (which wraps `VaultUseCases.GetVaultItems`)
/// and lets the user multi-select items to send into the current chat. Emits a
/// list of `AttachmentIntent.vaultItem` values back through `onSelect`.
struct EmbeddedVaultPickerView: View {

    // MARK: - Inputs

    var onSelect: ([AttachmentIntent]) -> Void
    var onCancel: () -> Void

    // MARK: - Environment

    @Environment(DependencyContainer.self) private var container

    // MARK: - State

    @State private var items: [VaultItem] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isLoading = true
    @State private var loadError: String?

    // MARK: - Styling

    private let backgroundColor = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x24 / 255)
    private let accentColor = Color(red: 0x6C / 255, green: 0x5C / 255, blue: 0xE7 / 255)

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 3
    )

    // MARK: - Derived

    private var selectedCount: Int { selectedIDs.count }

    private var vaultSource: VaultSource {
        let dataSource = VaultDataSource(
            grpcClient: container.grpcClient,
            mediaEncryption: container.mediaEncryption
        )
        let useCase = VaultUseCases.GetVaultItems(vaultDataSource: dataSource)
        return VaultSource(getVaultItems: useCase)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            sendBar
        }
        .background(backgroundColor.ignoresSafeArea())
        .task {
            await loadItems()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            Spacer()
            Text("Vault")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            // Spacer placeholder to balance the cancel button.
            Text("Cancel")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.clear)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            emptyState(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't Load Vault",
                subtitle: loadError
            )
        } else if items.isEmpty {
            emptyState(
                systemImage: "lock.shield",
                title: "Vault is Empty",
                subtitle: "Items you save to your vault will appear here."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        tile(for: item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private func tile(for item: VaultItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black.opacity(0.4)
                if let data = item.thumbnailData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.type.systemImage)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(accentColor)
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? accentColor : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            ZStack {
                Circle()
                    .fill(isSelected ? accentColor : Color.black.opacity(0.5))
                    .frame(width: 22, height: 22)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(6)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(item) }
    }

    private func emptyState(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .regular))
                .foregroundColor(accentColor)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sendBar: some View {
        let disabled = selectedCount == 0
        return Button(action: confirmSelection) {
            Text(disabled ? "Send" : "Send (\(selectedCount))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(disabled ? accentColor.opacity(0.35) : accentColor)
                )
        }
        .disabled(disabled)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func toggle(_ item: VaultItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func confirmSelection() {
        let intents: [AttachmentIntent] = items
            .filter { selectedIDs.contains($0.id) }
            .map { .vaultItem($0) }
        onSelect(intents)
    }

    private func loadItems() async {
        let source = vaultSource
        do {
            let loaded = try await source.loadAll()
            await MainActor.run {
                self.items = loaded
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}
