import SwiftUI

/// Profile screen for viewing and editing the current user's profile.
/// Matches Figma: header.
struct ProfileView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ProfileViewModel()

    var body: some View {
        List {
            // MARK: - Avatar Section
            Section {
                VStack(spacing: SanchrSpacing.md) {
                    // Avatar
                    Button {
                        // TODO: Photo picker for avatar
                    } label: {
                        Circle()
                            .fill(Color.sanchrPrimary.opacity(0.2))
                            .frame(width: 96, height: 96)
                            .overlay {
                                Image(systemName: "camera.fill")
                                    .font(.title2)
                                    .foregroundColor(.sanchrPrimary)
                            }
                    }

                    Text(viewModel.displayName)
                        .font(SanchrTypography.screenTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Text(viewModel.phoneNumber)
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SanchrSpacing.md)
            }
            .listRowBackground(Color.clear)

            // MARK: - Edit Fields
            Section("Profile") {
                HStack {
                    Text("Name")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    Spacer()
                    TextField("Display name", text: $viewModel.displayName)
                        .font(SanchrTypography.body)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("Bio")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    Spacer()
                    TextField("About you", text: $viewModel.bio)
                        .font(SanchrTypography.body)
                        .multilineTextAlignment(.trailing)
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Identity Verification
            Section("Security") {
                HStack(spacing: SanchrSpacing.xs) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.sanchrSuccess)
                    VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                        Text("Identity verified")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Text("Your identity key fingerprint is shared with your contacts for verification.")
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Save
            Section {
                Button {
                    Task { await viewModel.saveProfile(contactRepository: container.contactRepository) }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isSaving {
                            ProgressView()
                        } else {
                            Text("Save Changes")
                                .font(SanchrTypography.button)
                                .foregroundColor(.sanchrPrimary)
                        }
                        Spacer()
                    }
                }
                .disabled(!viewModel.hasChanges || viewModel.isSaving)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}
