import PhotosUI
import SwiftUI

struct OnboardingAvatarStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            // Back button
            HStack {
                Button {
                    viewModel.goToPreviousStep()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        .padding(SanchrSpacing.xs)
                }
                Spacer()
            }
            .padding(.horizontal, SanchrSpacing.md)

            Spacer()

            // Step indicator
            Text("STEP 2 OF 3")
                .font(SanchrTypography.micro)
                .foregroundColor(.sanchrPrimary)
                .kerning(2.5)
                .padding(.bottom, SanchrSpacing.sm)

            // Title
            Text("Add a photo")
                .font(SanchrTypography.screenTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                .padding(.bottom, SanchrSpacing.xs)

            // Subtitle
            Text("Help your friends recognize you")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                .padding(.bottom, SanchrSpacing.xxl)

            // Avatar circle
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                if let image = viewModel.selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .fill(Color.sanchrPrimary)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    Image(systemName: "pencil")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.white)
                                }
                        }
                } else {
                    Circle()
                        .strokeBorder(Color.sanchrPrimary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .frame(width: 120, height: 120)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 36, weight: .light))
                                .foregroundColor(.sanchrPrimary)
                        }
                }
            }

            Text(viewModel.selectedImage == nil ? "Tap to choose photo" : "Tap to change")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                .padding(.top, SanchrSpacing.sm)

            Spacer()

            // Progress + Continue
            VStack(spacing: SanchrSpacing.xl) {
                OnboardingProgressIndicator(currentStep: 2)

                Button {
                    viewModel.goToNextStep()
                } label: {
                    Text("Continue")
                        .font(SanchrTypography.button)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SanchrSpacing.md)
                        .background(SanchrGradients.primary)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                }
                .padding(.horizontal, SanchrSpacing.xxl)
            }
            .padding(.bottom, SanchrSpacing.xxxxl)
        }
        .sanchrScreenBackground()
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
