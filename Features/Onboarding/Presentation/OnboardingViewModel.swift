import Foundation
import UIKit

@MainActor
@Observable
final class OnboardingViewModel {

    // MARK: - Step State

    var currentStep: Int = 1
    var isForward: Bool = true

    // MARK: - Step 1: Name

    var displayName: String = ""

    var isNameValid: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Step 2: Avatar

    var selectedImage: UIImage?
    var avatarURL: String = ""

    // MARK: - Step 3: Save

    var isSaving: Bool = false
    var errorMessage: String?
    var notificationsEnabled: Bool = false

    // MARK: - Navigation

    func goToNextStep() {
        guard currentStep < 3 else { return }
        isForward = true
        currentStep += 1
    }

    func goToPreviousStep() {
        guard currentStep > 1 else { return }
        isForward = false
        currentStep -= 1
    }

    // MARK: - Notifications

    func requestNotificationPermission(pushManager: PushManager) async {
        let granted = await pushManager.requestAuthorization()
        notificationsEnabled = granted
    }

    // MARK: - Save Profile

    func saveProfile(
        profileDataSource: ProfileDataSource,
        mediaManager: MediaManagerProtocol,
        sessionService: SessionService
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            // Upload avatar if selected
            var finalAvatarURL = ""
            if let image = selectedImage {
                let uploadUseCase = ProfileUseCases.UploadAvatar(
                    profileDataSource: profileDataSource,
                    mediaManager: mediaManager
                )
                finalAvatarURL = try await uploadUseCase.execute(image: image)
            }

            // Save profile to server
            let updateUseCase = ProfileUseCases.UpdateProfile(
                profileDataSource: profileDataSource
            )
            _ = try await updateUseCase.execute(
                name: trimmedName,
                avatarURL: finalAvatarURL,
                status: ""
            )

            // Update session so RootView's needsOnboarding becomes false
            sessionService.updateProfile(
                displayName: trimmedName,
                avatarURL: finalAvatarURL.isEmpty ? nil : finalAvatarURL
            )

            SanchrLogger.auth.info("Onboarding profile saved for \(trimmedName)")
            return true
        } catch {
            errorMessage = "Failed to save profile. Please try again."
            SanchrLogger.auth.error("Onboarding save failed: \(error.localizedDescription)")
            return false
        }
    }
}
