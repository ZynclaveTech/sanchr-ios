import Foundation
import UIKit
import SanchrShared

@MainActor
@Observable
final class OnboardingViewModel {

    // MARK: - Step State

    static let totalSteps = 4

    /// Where a killed app resumes. The step and the typed name used to live
    /// only in this object, while the onboarding latch persisted, so a kill
    /// mid-flow restarted at an empty name field.
    private static let stepKey = "sanchr.onboarding.step"
    private static let nameKey = "sanchr.onboarding.name"
    private let defaults: UserDefaults

    var currentStep: Int = 1 {
        didSet { defaults.set(currentStep, forKey: Self.stepKey) }
    }
    var isForward: Bool = true

    // MARK: - Step 1: Name

    var displayName: String = "" {
        didSet { defaults.set(displayName, forKey: Self.nameKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: Self.stepKey)
        currentStep = min(max(stored, 1), Self.totalSteps)
        displayName = defaults.string(forKey: Self.nameKey) ?? ""
    }

    /// Onboarding is complete: forget the resume point.
    func finish() {
        defaults.removeObject(forKey: Self.stepKey)
        defaults.removeObject(forKey: Self.nameKey)
    }

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
        guard currentStep < Self.totalSteps else { return }
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
        profileKeyStore: ProfileKeyStoreProtocol,
        profileCrypto: ProfileCryptoProtocol,
        mediaManager: MediaManagerProtocol,
        sessionService: SessionService
    ) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // Upload avatar if selected (non-blocking — save name even if this fails)
        var finalAvatarURL = ""
        if let image = selectedImage {
            do {
                let uploadUseCase = ProfileUseCases.UploadAvatar(
                    profileDataSource: profileDataSource,
                    mediaManager: mediaManager
                )
                finalAvatarURL = try await uploadUseCase.execute(image: image)
            } catch {
                // Continuing silently saved a profile without the photo the
                // user just chose, and nothing ever told them. Stop here: the
                // step keeps the photo, so they can retry, or remove it and
                // continue without one.
                SanchrLogger.auth.warning("Avatar upload failed: \(error)")
                errorMessage = "Couldn't upload your photo. Try again, or remove it to continue without one."
                return false
            }
        }

        // Save profile to server (this must succeed)
        do {
            let updateUseCase = ProfileUseCases.UpdateProfile(
                profileDataSource: profileDataSource,
                profileKeyStore: profileKeyStore,
                profileCrypto: profileCrypto
            )
            _ = try await updateUseCase.execute(
                name: self.trimmedName,
                avatarURL: finalAvatarURL,
                status: ""
            )

            // Update session so RootView's needsOnboarding becomes false
            sessionService.updateProfile(
                displayName: self.trimmedName,
                avatarURL: finalAvatarURL.isEmpty ? nil : finalAvatarURL
            )

            SanchrLogger.auth.info("Onboarding profile saved for \(self.trimmedName)")
            return true
        } catch {
            errorMessage = "Failed to save profile: \(error.localizedDescription)"
            SanchrLogger.auth.error("Onboarding save failed: \(error)")
            return false
        }
    }
}
