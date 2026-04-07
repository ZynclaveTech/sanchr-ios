import PhotosUI
import SwiftUI
import SanchrShared

struct OnboardingAvatarStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @State private var selectedPhotoItem: PhotosPickerItem?
    let profileDataSource: ProfileDataSource
    let mediaManager: MediaManagerProtocol
    let sessionService: SessionService

    var body: some View {
        let selectedImage = viewModel.selectedImage

        VStack(spacing: 0) {
            HStack {
                SanchrIconButton(systemName: "chevron.left") {
                    viewModel.goToPreviousStep()
                }
                Spacer()
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.top, 12)

            Spacer(minLength: 28)

            Text("STEP 2 OF 3")
                .font(SanchrTypography.micro)
                .foregroundColor(.sanchrPrimary)
                .kerning(2.5)
                .padding(.bottom, 12)

            Text("Add a photo")
                .font(SanchrTypography.displayTitle)
                .foregroundColor(SanchrExportColors.textPrimary)
                .padding(.bottom, 8)

            Text("Help your contacts recognize you instantly.")
                .font(SanchrTypography.body)
                .foregroundColor(SanchrExportColors.textSecondary)
                .padding(.bottom, 30)

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    if let image = selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 148, height: 148)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .strokeBorder(
                                SanchrColors.primary,
                                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                            )
                            .frame(width: 148, height: 148)
                            .background(
                                Circle()
                                    .fill(SanchrExportColors.surfaceSoft)
                            )
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.sanchrPrimary)
                            }
                    }

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [SanchrColors.primary, Color(hex: 0x4F46E5)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 38, height: 38)
                        .overlay {
                            Image(systemName: selectedImage == nil ? "camera.fill" : "pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                }
            }

            Text(selectedImage == nil ? "Tap to choose photo" : "Tap to change photo")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
                .padding(.top, 14)

            Spacer()

            VStack(spacing: 18) {
                OnboardingProgressIndicator(currentStep: 2)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                }

                Button {
                    Task {
                        let saved = await viewModel.saveProfile(
                            profileDataSource: profileDataSource,
                            mediaManager: mediaManager,
                            sessionService: sessionService
                        )
                        if saved {
                            viewModel.goToNextStep()
                        }
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                LinearGradient(
                                    colors: [SanchrColors.primary, Color(hex: 0x4F46E5)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                    } else {
                        SanchrGradientButtonLabel(title: "Continue", systemName: nil)
                    }
                }
                .buttonStyle(SanchrPrimaryCTA())
                .disabled(viewModel.isSaving)
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            }
            .padding(.bottom, 36)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                guard
                    let data = try? await newValue.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                else {
                    return
                }

                await MainActor.run {
                    viewModel.selectedImage = image
                }
            }
        }
    }
}
