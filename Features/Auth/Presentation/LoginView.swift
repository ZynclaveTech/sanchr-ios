import SwiftUI
import SanchrShared

struct LoginView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = AuthViewModel()
    @State private var presentedLegalDocument: LegalDocument?

    @State private var showCountryPicker = false

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
            .sheet(isPresented: $showCountryPicker) {
                CountryPickerView(selection: $viewModel.country)
            }
        }
    }

    /// Shows the number formatted; stores digits. A formatted string in the
    /// model would have had to be unformatted before every use.
    private var phoneField: Binding<String> {
        Binding(
            get: { viewModel.formattedPhoneNumber },
            set: { viewModel.phoneNumber = $0 }
        )
    }

    private var heroSection: some View {
        VStack(spacing: 0) {
            Image("SanchrLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)

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
                Button {
                    showCountryPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Text(viewModel.country.flag)
                            .font(.title2)
                        Text(viewModel.countryCode)
                            .font(SanchrTypography.body)
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 60)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(SanchrExportColors.line)
                            .frame(width: 1, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Country, \(viewModel.country.name) \(viewModel.countryCode)")
                .accessibilityHint("Choose a different country")

                TextField(viewModel.country.placeholder, text: phoneField)
                    .font(SanchrTypography.bodyBold)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding(.horizontal, 14)
                    .frame(height: 60)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .accessibilityLabel("Phone number")
                    .accessibilityValue(viewModel.displayPhoneNumber)
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
            .sanchrShadow(0.04, radius: 18, y: 10)

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
        .accessibilityLabel(viewModel.isLoading ? "Sending verification code" : "Continue")
        .accessibilityHint(viewModel.isPhoneValid ? "Sends a verification code by text message" : "Enter your phone number first")
    }

    private var privacyLinks: some View {
        // Real links, opened in-app. Plain text here claimed agreement to
        // documents the user had no way to read.
        Text(.init("By continuing, you agree to our [Privacy Policy](\(LegalDocument.privacy.url)) and [Terms of Service](\(LegalDocument.terms.url))"))
            .font(SanchrTypography.captionSmall)
            .foregroundColor(SanchrExportColors.textSecondary)
            .tint(SanchrColors.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .environment(\.openURL, OpenURLAction { url in
                guard let document = LegalDocument(url: url) else { return .systemAction }
                presentedLegalDocument = document
                return .handled
            })
            .sheet(item: $presentedLegalDocument) { document in
                SafariSheet(url: document.url)
                    .ignoresSafeArea()
            }
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
