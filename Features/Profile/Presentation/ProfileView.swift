import SwiftUI
import PhotosUI

/// Profile screen for viewing and editing the current user's profile.
/// Matches Figma: header screen with large avatar, name, phone, status, QR code, action buttons.
@MainActor
struct ProfileView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ProfileViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showQRCode = false

    private var profileDataSource: ProfileDataSource {
        ProfileDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        List {
            // MARK: - Avatar Section
            Section {
                VStack(spacing: SanchrSpacing.md) {
                    // Large avatar with edit button
                    ZStack(alignment: .bottomTrailing) {
                        if let url = URL(string: viewModel.avatarURL), !viewModel.avatarURL.isEmpty {
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                avatarPlaceholder
                            }
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                        } else {
                            avatarPlaceholder
                        }

                        // Edit button overlay
                        if viewModel.isEditing {
                            let isUploading = viewModel.isUploadingAvatar
                            let currentScheme = colorScheme
                            PhotosPicker(
                                selection: $selectedPhotoItem,
                                matching: .images
                            ) {
                                Circle()
                                    .fill(Color.sanchrPrimary)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if isUploading {
                                            ProgressView()
                                                .tint(.white)
                                                .scaleEffect(0.7)
                                        } else {
                                            Image(systemName: "camera.fill")
                                                .font(.caption)
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .overlay(
                                        Circle()
                                            .stroke(Color.sanchrBackground(currentScheme), lineWidth: 3)
                                    )
                            }
                        }
                    }

                    // Display name
                    Text(viewModel.displayName)
                        .font(SanchrTypography.screenTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    // Phone number
                    Text(viewModel.phoneNumber)
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                    // Status text
                    if !viewModel.statusText.isEmpty && !viewModel.isEditing {
                        Text(viewModel.statusText)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                            .multilineTextAlignment(.center)
                    }

                    // Action buttons (message, call, video, QR share)
                    if !viewModel.isEditing {
                        HStack(spacing: SanchrSpacing.xl) {
                            profileActionButton(icon: "qrcode", label: "QR Code") {
                                showQRCode = true
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SanchrSpacing.md)
            }
            .listRowBackground(Color.clear)

            // MARK: - Edit Fields
            Section("Profile") {
                if viewModel.isEditing {
                    HStack {
                        Text("Name")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                            .frame(width: 60, alignment: .leading)
                        TextField("Display name", text: $viewModel.displayName)
                            .font(SanchrTypography.body)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Status")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                            .frame(width: 60, alignment: .leading)
                        TextField("What's on your mind?", text: $viewModel.statusText)
                            .font(SanchrTypography.body)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    HStack {
                        Text("Name")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        Spacer()
                        Text(viewModel.displayName)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    }

                    HStack {
                        Text("Phone")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        Spacer()
                        Text(viewModel.phoneNumber)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    }

                    HStack {
                        Text("Status")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        Spacer()
                        Text(viewModel.statusText.isEmpty ? "Not set" : viewModel.statusText)
                            .font(SanchrTypography.body)
                            .foregroundColor(
                                viewModel.statusText.isEmpty
                                    ? Color.sanchrTextTertiary(colorScheme)
                                    : Color.sanchrTextPrimary(colorScheme)
                            )
                    }
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

            // MARK: - Save / Edit Button
            Section {
                if viewModel.isEditing {
                    // Save button
                    Button {
                        Task {
                            await viewModel.saveProfile(
                                profileDataSource: profileDataSource,
                                sessionService: container.sessionService
                            )
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isSaving {
                                ProgressView()
                            } else {
                                Text("Save Changes")
                                    .font(SanchrTypography.button)
                                    .foregroundColor(viewModel.hasChanges ? .sanchrPrimary : Color.sanchrTextTertiary(colorScheme))
                            }
                            Spacer()
                        }
                    }
                    .disabled(!viewModel.hasChanges || viewModel.isSaving)

                    // Cancel button
                    Button {
                        viewModel.cancelEdit()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Cancel")
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                            Spacer()
                        }
                    }
                } else {
                    Button {
                        viewModel.isEditing = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Edit Profile")
                                .font(SanchrTypography.button)
                                .foregroundColor(.sanchrPrimary)
                            Spacer()
                        }
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Error
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showQRCode) {
            qrCodeSheet
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await viewModel.uploadAvatar(
                        image: image,
                        profileDataSource: profileDataSource,
                        mediaManager: container.mediaManager
                    )
                }
            }
        }
        .task {
            await viewModel.loadProfile(sessionService: container.sessionService)
        }
    }

    // MARK: - Avatar Placeholder

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.sanchrPrimary.opacity(0.2))
            .frame(width: 96, height: 96)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.sanchrPrimary)
            }
    }

    // MARK: - Action Button

    private func profileActionButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: SanchrSpacing.xxs) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.sanchrPrimary)
                    .frame(width: 48, height: 48)
                    .background(Color.sanchrPrimary.opacity(0.1))
                    .clipShape(Circle())

                Text(label)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }
        }
    }

    // MARK: - QR Code Sheet

    private var qrCodeSheet: some View {
        NavigationStack {
            VStack(spacing: SanchrSpacing.xl) {
                Spacer()

                Text("Share Your Profile")
                    .font(SanchrTypography.screenTitle)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                // QR Code placeholder (would generate from userId)
                RoundedRectangle(cornerRadius: SanchrRadius.card)
                    .fill(Color.white)
                    .frame(width: 200, height: 200)
                    .overlay {
                        Image(systemName: "qrcode")
                            .font(.system(size: 120))
                            .foregroundColor(.black)
                    }
                    .sanchrCardShadow()

                Text(viewModel.displayName)
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                Text("Scan this code to add me on Sanchr")
                    .font(SanchrTypography.caption)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                Spacer()

                Button {
                    // Share QR code image
                } label: {
                    Text("Share")
                        .font(SanchrTypography.button)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SanchrSpacing.sm)
                        .background(SanchrGradients.primary)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                }
                .padding(.horizontal, SanchrSpacing.xl)
                .padding(.bottom, SanchrSpacing.xl)
            }
            .sanchrScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showQRCode = false }
                }
            }
        }
        .presentationDetents([.large])
    }
}
