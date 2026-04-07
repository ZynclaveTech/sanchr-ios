import SwiftUI
import SanchrShared

struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = AuthViewModel()

    private let countryCodes = [
        ("+1", "US"),
        ("+44", "UK"),
        ("+91", "IN"),
        ("+61", "AU"),
        ("+81", "JP"),
        ("+49", "DE"),
        ("+33", "FR"),
        ("+86", "CN"),
        ("+55", "BR"),
        ("+234", "NG"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 54)

                    heroSection

                    Spacer()
                        .frame(height: 44)

                    phoneSection

                    Spacer()
                        .frame(height: 18)

                    securityCard

                    Spacer()
                        .frame(height: 28)

                    continueButton

                    Spacer()
                        .frame(height: 24)

                    privacyLinks

                    #if DEBUG
                    Spacer()
                        .frame(height: 28)

                    debugResetSection
                    #endif
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SanchrExportColors.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $viewModel.showOTPView) {
                OTPView(viewModel: viewModel)
            }
        }
    }

    private var heroSection: some View {
        VStack(spacing: 0) {
            Image("SanchrLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            Spacer()
                .frame(height: 40)

            Text("Welcome to Sanchr")
                .font(SanchrTypography.displayTitle)
                .foregroundColor(SanchrExportColors.textPrimary)
                .multilineTextAlignment(.center)

            Spacer()
                .frame(height: 14)

            Text("Encrypted. Synced. Secure.")
                .font(SanchrTypography.body)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Phone Number")
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)

            Spacer()
                .frame(height: 14)

            HStack(spacing: 0) {
                Menu {
                    ForEach(countryCodes, id: \.0) { code, region in
                        Button {
                            viewModel.countryCode = code
                        } label: {
                            HStack {
                                Text("\(code) \(region)")
                                if viewModel.countryCode == code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe.europe.africa.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(SanchrColors.primary)

                        Text(viewModel.countryCode)
                            .font(SanchrTypography.body)
                            .foregroundColor(SanchrExportColors.textPrimary)
                    }
                    .frame(width: 88, height: 60)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(SanchrExportColors.line)
                            .frame(width: 1, height: 28)
                            .padding(.trailing, 1)
                    }
                }
                .buttonStyle(.plain)

                TextField("(555) 123-4567", text: $viewModel.phoneNumber)
                    .font(SanchrTypography.bodyBold)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding(.horizontal, 18)
                    .frame(height: 60)
                    .foregroundColor(SanchrExportColors.textPrimary)
            }
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        viewModel.errorMessage == nil ? SanchrExportColors.line : SanchrColors.error.opacity(0.35),
                        lineWidth: 1.2
                    )
            }
            .shadow(color: Color.black.opacity(0.04), radius: 18, x: 0, y: 10)

            Spacer()
                .frame(height: 14)

            Text("We'll send you a verification code")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)

            if let error = viewModel.errorMessage {
                Spacer()
                    .frame(height: 10)

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text(error)
                        .font(SanchrTypography.caption)
                }
                .foregroundColor(SanchrColors.error)
            }
        }
    }

    private var securityCard: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SanchrColors.primary.opacity(0.1))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(SanchrColors.primary)
                }

            VStack(alignment: .leading, spacing: 8) {
                Text("End-to-End Encrypted")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text("Your messages are secured with military-grade encryption. Only you and your contacts can read them.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(SanchrExportColors.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SanchrColors.primary.opacity(colorScheme == .dark ? 0.15 : 0.12), lineWidth: 1)
        }
    }

    private var continueButton: some View {
        Button {
            Task { @MainActor in
                await viewModel.requestOTP(authService: container.authService)
            }
        } label: {
            HStack(spacing: 12) {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Continue")
                        .font(SanchrTypography.cardTitle)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                LinearGradient(
                    colors: [SanchrColors.primary, SanchrColors.primaryDark],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: SanchrColors.primary.opacity(0.22), radius: 20, x: 0, y: 10)
        }
        .buttonStyle(SanchrPrimaryCTA())
        .disabled(!viewModel.isPhoneValid || viewModel.isLoading)
        .opacity(viewModel.isPhoneValid ? 1 : 0.58)
    }

    private var privacyLinks: some View {
        Text("By continuing, you agree to our Privacy Policy and Terms of Service")
            .font(SanchrTypography.captionSmall)
            .foregroundColor(SanchrExportColors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    #if DEBUG
    private var debugResetSection: some View {
        Button {
            Task { await container.resetLocalSecretsForDebug() }
        } label: {
            Text("Reset Local Secrets")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrColors.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(SanchrColors.primary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    #endif

}
