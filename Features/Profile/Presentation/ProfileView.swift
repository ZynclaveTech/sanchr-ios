import Kingfisher
import SwiftUI
import PhotosUI
import SanchrShared

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

    private var profileKeyStore: ProfileKeyStoreProtocol {
        ProfileKeyStore(keychain: container.keychainService)
    }

    private let profileCrypto: ProfileCryptoProtocol = ProfileCryptor()

    var body: some View {
        List {
            // MARK: - Avatar Section
            Section {
                VStack(spacing: SanchrSpacing.md) {
                    // Large avatar with edit button
                    ZStack(alignment: .bottomTrailing) {
                        if let url = URL(string: viewModel.avatarURL), !viewModel.avatarURL.isEmpty {
                            KFImage(url)
                                .resizable()
                                .placeholder { avatarPlaceholder }
                                .fade(duration: 0.2)
                                .scaledToFill()
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
                                profileKeyStore: profileKeyStore,
                                profileCrypto: profileCrypto,
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
                    .disabled(!viewModel.hasChanges || viewModel.isSaving || !viewModel.hasDisplayName)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

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
                        profileKeyStore: profileKeyStore,
                        profileCrypto: profileCrypto,
                        mediaManager: container.mediaManager,
                        sessionService: container.sessionService
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

    // MARK: - QR Code Sheet (Glass Card with Brand Ring)

    private var qrCodeSheet: some View {
        NavigationStack {
            VStack(spacing: SanchrSpacing.xl) {
                Spacer()

                // Glass card container
                VStack(spacing: SanchrSpacing.lg) {
                    // QR code with gradient brand ring
                    ZStack {
                        // Outer gradient ring
                        RoundedRectangle(cornerRadius: SanchrRadius.lg)
                            .fill(SanchrGradients.primary)
                            .frame(width: 226, height: 226)

                        // White inner surface
                        RoundedRectangle(cornerRadius: SanchrRadius.lg - 2)
                            .fill(Color.white)
                            .frame(width: 220, height: 220)

                        // QR code image
                        if let qrImage = generateQRCode() {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 190, height: 190)
                        }
                    }

                    // User display name
                    Text(viewModel.displayName)
                        .font(SanchrTypography.cardTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    // Subtitle
                    Text("Scan to add on Sanchr")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                    // E2EE badge pill
                    HStack(spacing: SanchrSpacing.xxs) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("End-to-end encrypted")
                            .font(SanchrTypography.scaled(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, SanchrSpacing.sm)
                    .padding(.vertical, SanchrSpacing.xxs + 2)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                }
                .padding(SanchrSpacing.xl)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.sanchrPrimary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.sanchrPrimary.opacity(0.12), lineWidth: 1)
                        )
                )
                .padding(.horizontal, SanchrSpacing.xl)

                Spacer()

                // Action buttons: Share (flex) + Save (icon)
                HStack(spacing: SanchrSpacing.sm) {
                    Button(action: shareQRCode) {
                        HStack(spacing: SanchrSpacing.xs) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Share")
                                .font(SanchrTypography.button)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SanchrSpacing.sm + 2)
                        .background(SanchrColors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                    }
                    .buttonStyle(.plain)

                    Button(action: saveQRCode) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sanchrPrimary)
                            .frame(width: 48, height: 48)
                            .background(Color.sanchrPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                    }
                    .accessibilityLabel("Save QR code")
                    .buttonStyle(.plain)
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

    // MARK: - QR Code Helpers

    /// Renders the Sanchr logo mark as a gradient-filled UIImage for QR center overlay.
    private func sanchrLogoMark() -> UIImage {
        let size: CGFloat = 36
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.22)
            path.addClip()
            // Indigo-to-cyan gradient matching SanchrGradients.primary
            let colors: [CGColor] = [
                UIColor(red: 99 / 255, green: 102 / 255, blue: 241 / 255, alpha: 1).cgColor,  // #6366F1
                UIColor(red: 6 / 255, green: 182 / 255, blue: 212 / 255, alpha: 1).cgColor,   // #06B6D4
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0.0, 1.0]
            ) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size, y: size),
                    options: []
                )
            }
            // "S" letter centered
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: size * 0.55),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle,
            ]
            let text = "S"
            let textSize = text.size(withAttributes: attrs)
            let textRect = CGRect(
                x: (size - textSize.width) / 2,
                y: (size - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
        }
    }

    /// Generates the QR code image with the Sanchr logo mark at center.
    private func generateQRCode() -> UIImage? {
        let deepLink = "https://sanchr.com/u/\(viewModel.userId)"
        return QRCodeGenerator.generate(
            from: deepLink,
            size: 190,
            logoImage: sanchrLogoMark(),
            logoSizeFraction: 0.18
        )
    }

    /// Presents the system share sheet with a rendered QR card image.
    private func shareQRCode() {
        guard let qrImage = generateQRCode() else { return }
        let activityVC = UIActivityViewController(
            activityItems: [qrImage],
            applicationActivities: nil
        )
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController
        else { return }
        // Walk to the top-most presented view controller
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(activityVC, animated: true)
    }

    /// Saves the QR code image to the user's Photos library.
    private func saveQRCode() {
        guard let qrImage = generateQRCode() else { return }
        UIImageWriteToSavedPhotosAlbum(qrImage, nil, nil, nil)
    }
}
