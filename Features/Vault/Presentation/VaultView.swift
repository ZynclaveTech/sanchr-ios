import SwiftUI

/// Encrypted vault screen for secure file storage.
/// Matches Figma: vault-screen.
struct VaultView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = VaultViewModel()
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.items.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: SanchrSpacing.sm),
                                GridItem(.flexible(), spacing: SanchrSpacing.sm),
                            ],
                            spacing: SanchrSpacing.sm
                        ) {
                            ForEach(viewModel.items) { item in
                                VaultItemCard(item: item, colorScheme: colorScheme)
                            }
                        }
                        .padding(SanchrSpacing.md)
                    }
                }
            }
            .navigationTitle("Vault")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.sanchrPrimary)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                // TODO: File picker / camera for vault upload
                Text("Add to Vault")
                    .presentationDetents([.medium])
            }
            .task {
                await viewModel.loadItems(vaultRepository: container.vaultRepository)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: SanchrSpacing.md) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 64))
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            Text("Your vault is empty")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
            Text("Store photos, documents, and notes with end-to-end encryption")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                .multilineTextAlignment(.center)

            Button {
                showAddSheet = true
            } label: {
                Text("Add your first item")
                    .font(SanchrTypography.button)
                    .foregroundColor(.white)
                    .padding(.horizontal, SanchrSpacing.xl)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(SanchrGradients.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
            }
        }
        .padding(.horizontal, SanchrSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sanchrScreenBackground()
    }
}

// MARK: - Vault Item Card

struct VaultItemCard: View {
    let item: VaultItem
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
            // Thumbnail / Icon
            RoundedRectangle(cornerRadius: SanchrRadius.sm)
                .fill(Color.sanchrSurface(colorScheme))
                .frame(height: 120)
                .overlay {
                    Image(systemName: item.type.systemImage)
                        .font(.largeTitle)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }

            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                Text(item.name)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    .lineLimit(1)

                Text(item.formattedSize)
                    .font(SanchrTypography.micro)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
        }
        .sanchrCard()
    }
}
