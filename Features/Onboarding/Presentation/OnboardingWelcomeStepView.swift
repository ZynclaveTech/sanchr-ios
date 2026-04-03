import SwiftUI

struct OnboardingWelcomeStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme

    let pushManager: PushManager
    let profileDataSource: ProfileDataSource
    let mediaManager: MediaManagerProtocol
    let sessionService: SessionService

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
            Text("YOU'RE ALL SET")
                .font(SanchrTypography.micro)
                .foregroundColor(.sanchrPrimary)
                .kerning(2.5)
                .padding(.bottom, SanchrSpacing.md)

            // Avatar preview
            if let image = viewModel.selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .padding(.bottom, SanchrSpacing.md)
            } else {
                Circle()
                    .fill(SanchrGradients.primary)
                    .frame(width: 96, height: 96)
                    .overlay {
                        Text(String(viewModel.trimmedName.prefix(1)).uppercased())
                            .font(SanchrTypography.heroTitle)
                            .foregroundColor(.white)
                    }
                    .padding(.bottom, SanchrSpacing.md)
            }

            // Welcome title
            Text("Welcome, \(viewModel.trimmedName)!")
                .font(SanchrTypography.screenTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                .padding(.bottom, SanchrSpacing.xs)

            // E2EE tagline
            Text("Your messages are end-to-end encrypted. Only you and the people you chat with can read them.")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.bottom, SanchrSpacing.xxl)

            // Notification permission card
            if !viewModel.notificationsEnabled {
                notificationCard
                    .padding(.horizontal, SanchrSpacing.xxl)
                    .padding(.bottom, SanchrSpacing.lg)
            }

            Spacer()

            // Progress + Start Chatting
            VStack(spacing: SanchrSpacing.xl) {
                OnboardingProgressIndicator(currentStep: 3)

                // Error message
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(.sanchrError)
                        .padding(.horizontal, SanchrSpacing.xxl)
                }

                Button {
                    Task {
                        _ = await viewModel.saveProfile(
                            profileDataSource: profileDataSource,
                            mediaManager: mediaManager,
                            sessionService: sessionService
                        )
                    }
                } label: {
                    HStack(spacing: SanchrSpacing.xs) {
                        if viewModel.isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(viewModel.errorMessage != nil ? "Retry" : "Start Chatting")
                                .font(SanchrTypography.button)
                                .foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SanchrSpacing.md)
                    .background(SanchrGradients.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                }
                .disabled(viewModel.isSaving)
                .padding(.horizontal, SanchrSpacing.xxl)
            }
            .padding(.bottom, SanchrSpacing.xxxxl)
        }
        .sanchrScreenBackground()
        .task {
            await viewModel.requestNotificationPermission(pushManager: pushManager)
        }
    }

    // MARK: - Notification Card

    private var notificationCard: some View {
        VStack(spacing: SanchrSpacing.sm) {
            HStack(spacing: SanchrSpacing.sm) {
                Image(systemName: "bell.badge.fill")
                    .font(.title3)
                    .foregroundColor(.sanchrPrimary)
                VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                    Text("Enable Notifications")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Text("Know when you receive messages")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }
                Spacer()
                Button {
                    Task {
                        await viewModel.requestNotificationPermission(pushManager: pushManager)
                    }
                } label: {
                    Text("Enable")
                        .font(SanchrTypography.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, SanchrSpacing.md)
                        .padding(.vertical, SanchrSpacing.xs)
                        .background(Color.sanchrPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))
                }
            }
        }
        .padding(SanchrSpacing.md)
        .background(Color.sanchrSurface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
    }
}
