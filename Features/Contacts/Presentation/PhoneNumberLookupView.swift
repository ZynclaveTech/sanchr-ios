import Kingfisher
import SwiftUI
import SanchrShared

struct PhoneNumberLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DependencyContainer.self) private var container
    @Environment(AppRouter.self) private var router

    @State private var phoneNumber = ""
    @State private var countryCode: String = Self.defaultCountryCode()
    @State private var state: LookupState = .idle
    @State private var isStartingChat = false
    @State private var lastSearchedNumber = ""

    private enum LookupState {
        case idle
        case searching
        case found(User)
        case notFound
        case error(String)
    }

    private static let countryCodes: [(code: String, region: String)] = [
        ("+1",   "US"),
        ("+44",  "UK"),
        ("+91",  "IN"),
        ("+61",  "AU"),
        ("+81",  "JP"),
        ("+49",  "DE"),
        ("+33",  "FR"),
        ("+86",  "CN"),
        ("+55",  "BR"),
        ("+234", "NG"),
    ]

    /// Picks the dialling prefix that matches the device region, falling back to +1.
    private static func defaultCountryCode() -> String {
        let regionId = Locale.current.region?.identifier ?? ""
        return countryCodes.first { $0.region == regionId }?.code ?? "+1"
    }

    private var isPhoneValid: Bool {
        phoneNumber.filter(\.isNumber).count >= 6
    }

    private var isSearching: Bool {
        if case .searching = state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: SanchrSpacing.xl) {

                    // Header
                    VStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "phone.badge.plus")
                            .font(.system(size: 36))
                            .foregroundStyle(SanchrGradients.primaryDark)
                            .frame(width: 80, height: 80)
                            .background(SanchrColors.primary.opacity(0.12))
                            .clipShape(Circle())

                        Text("Find by Phone Number")
                            .font(SanchrTypography.cardTitle)
                            .foregroundColor(SanchrExportColors.textPrimary)
                    }
                    .padding(.top, SanchrSpacing.xl)

                    // Phone input — same layout as LoginView
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Phone Number")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)

                        Spacer().frame(height: 14)

                        HStack(spacing: 0) {
                            // Country picker
                            Menu {
                                ForEach(Self.countryCodes, id: \.code) { item in
                                    Button {
                                        countryCode = item.code
                                    } label: {
                                        HStack {
                                            Text("\(item.code) \(item.region)")
                                            if countryCode == item.code {
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

                                    Text(countryCode)
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

                            // Number field (no country code — it's in the picker)
                            TextField("(555) 123-4567", text: $phoneNumber)
                                .font(SanchrTypography.bodyBold)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                                .padding(.horizontal, 18)
                                .frame(height: 60)
                                .foregroundColor(SanchrExportColors.textPrimary)
                                .onChange(of: phoneNumber) { _, _ in
                                    if case .idle = state { } else { state = .idle }
                                }
                        }
                        .background(SanchrExportColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(SanchrExportColors.line, lineWidth: 1.2)
                        }
                        .shadow(color: Color.black.opacity(0.04), radius: 18, x: 0, y: 10)

                        Spacer().frame(height: 10)

                        Text("Enter the number without the country code")
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

                    // Search button
                    Button {
                        Task { await performLookup() }
                    } label: {
                        if isSearching {
                            HStack(spacing: SanchrSpacing.xs) {
                                ProgressView().tint(.white)
                                Text("Searching…")
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(SanchrColors.primary)
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                        } else {
                            SanchrGradientButtonLabel(title: "Find Contact", systemName: "magnifyingglass")
                        }
                    }
                    .disabled(!isPhoneValid || isSearching)
                    .opacity(isPhoneValid ? 1.0 : 0.5)
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

                    // Result
                    resultView
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)

                    Spacer(minLength: SanchrSpacing.xl)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sanchrScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Result view

    @ViewBuilder
    private var resultView: some View {
        switch state {
        case .idle, .searching:
            EmptyView()

        case .found(let user):
            FoundUserCard(
                isIdentityVerified: container.signalProtocol
                    .isIdentityVerified(userId: user.id),
                user: user,
                isStartingChat: isStartingChat,
                onMessage: { Task { await startChat(with: user) } }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))

        case .notFound:
            InviteCard(phoneNumber: lastSearchedNumber)
                .transition(.move(edge: .bottom).combined(with: .opacity))

        case .error(let message):
            feedbackCard(
                icon: "exclamationmark.triangle.fill",
                iconColor: SanchrColors.error,
                title: "Search failed",
                subtitle: message,
                background: SanchrColors.error.opacity(0.08)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func feedbackCard(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        background: Color
    ) -> some View {
        HStack(spacing: SanchrSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(SanchrSpacing.md)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
    }

    // MARK: - Actions

    private func performLookup() async {
        let digits = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty else { return }
        let fullNumber = "\(countryCode)\(digits)"
        lastSearchedNumber = fullNumber

        withAnimation(.easeInOut(duration: 0.2)) { state = .searching }

        do {
            if let user = try await container.contactRepository.searchUser(phoneNumber: fullNumber) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    state = .found(user)
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { state = .notFound }
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func startChat(with user: User) async {
        guard !isStartingChat else { return }
        isStartingChat = true
        defer { isStartingChat = false }

        do {
            let conversationId = try await container.messageRepository.startDirectConversation(peerUserId: user.id)
            dismiss()
            try? await Task.sleep(nanoseconds: 300_000_000)
            router.deepLinkToConversation(conversationId: conversationId)
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) {
                state = .error(error.localizedDescription)
            }
        }
    }
}

// MARK: - Found User Card

private struct FoundUserCard: View {
    /// Whether this person's identity key has been verified — not whether they
    /// have an account. See `User.isVerified`.
    let isIdentityVerified: Bool
    let user: User
    let isStartingChat: Bool
    let onMessage: () -> Void

    var body: some View {
        VStack(spacing: SanchrSpacing.md) {
            HStack(spacing: SanchrSpacing.sm) {
                Group {
                    if let avatarURL = user.avatarURL {
                        KFImage(avatarURL)
                            .resizable()
                            .placeholder { avatarPlaceholder }
                            .fade(duration: 0.2)
                            .scaledToFill()
                    } else {
                        avatarPlaceholder
                    }
                }
                .frame(width: SanchrSpacing.chatAvatarSize, height: SanchrSpacing.chatAvatarSize)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(user.displayName)
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .lineLimit(1)
                        if isIdentityVerified {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(SanchrColors.accent)
                        }
                    }
                    Text(user.bio?.isEmpty == false ? user.bio! : user.phoneNumber)
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if user.status == .online {
                    Circle()
                        .fill(SanchrColors.statusOnline)
                        .frame(width: 10, height: 10)
                }
            }

            Divider().background(SanchrExportColors.line)

            Button(action: onMessage) {
                if isStartingChat {
                    HStack(spacing: SanchrSpacing.xs) {
                        ProgressView().tint(.white)
                        Text("Opening chat…")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(SanchrColors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                } else {
                    HStack(spacing: SanchrSpacing.xs) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Message")
                            .font(SanchrTypography.bodyBold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(SanchrGradients.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                }
            }
            .buttonStyle(.plain)
            .disabled(isStartingChat)
        }
        .padding(SanchrSpacing.md)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: SanchrRadius.card)
                .stroke(SanchrColors.primary.opacity(0.18), lineWidth: 1)
        )
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(SanchrColors.primary.opacity(0.14))
            .overlay {
                Text(user.displayName.prefix(1).uppercased())
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.sanchrPrimary)
            }
    }
}

// MARK: - Invite Card

private struct InviteCard: View {
    let phoneNumber: String

    private static let inviteMessage =
        "Hey! I use Sanchr for private, end-to-end encrypted messaging. Join me — download it at https://sanchr.com/download"

    var body: some View {
        VStack(alignment: .leading, spacing: SanchrSpacing.md) {
            // Header row
            HStack(spacing: SanchrSpacing.sm) {
                Image(systemName: "person.slash.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Not on Sanchr yet")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text("Invite them to join the conversation.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer(minLength: 0)
            }

            Divider().background(SanchrExportColors.line)

            // Invite via SMS
            Button {
                sendInviteSMS()
            } label: {
                HStack(spacing: SanchrSpacing.xs) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Invite via SMS")
                        .font(SanchrTypography.bodyBold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(SanchrGradients.primary)
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
            }
            .buttonStyle(.plain)
        }
        .padding(SanchrSpacing.md)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
    }

    private func sendInviteSMS() {
        // Encode the body for the SMS URL scheme
        let body = Self.inviteMessage
        guard let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "sms:\(phoneNumber)&body=\(encoded)"),
              UIApplication.shared.canOpenURL(url)
        else {
            // Fallback: open without pre-filled number if the scheme isn't available
            if let fallback = URL(string: "sms:"),
               UIApplication.shared.canOpenURL(fallback) {
                UIApplication.shared.open(fallback)
            }
            return
        }
        UIApplication.shared.open(url)
    }
}
