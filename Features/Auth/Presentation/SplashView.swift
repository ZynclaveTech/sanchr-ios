import SwiftUI
import SanchrShared

/// Full-screen splash shown during app launch.
///
/// Animation sequence (all driven by `appeared`):
///   0.00 s — ambient glow fades in (0.60 s, easeOut)
///   0.10 s — logo scales up from 0.75× with spring overshoot (0.55 s)
///   0.50 s — wordmark fades up (0.40 s, easeOut)
///   0.65 s — tagline fades up (0.40 s, easeOut)
///   0.85 s — spinner + caption fade up (0.35 s, easeOut)
struct SplashView: View {

    @State private var appeared = false
    /// Supplied by the root so the mark can glide into the lock screen.
    var markNamespace: Namespace.ID? = nil

    var body: some View {
        ZStack {
            // Always-dark background — does not follow system appearance.
            Color(hex: 0x08080E)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                // ── Logo + ambient glow ──────────────────────────────────
                ZStack {
                    // Soft radial glow behind the logo
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.sanchrPrimary.opacity(0.18),
                                    Color.clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 90
                            )
                        )
                        .frame(width: 180, height: 180)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.60).delay(0.00), value: appeared)

                    // Real SanchrLogo asset — blends into dark bg via .screen
                    Image("SanchrLogo")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .blendMode(.screen)
                        .scaleEffect(appeared ? 1.0 : 0.75)
                        .opacity(appeared ? 1 : 0)
                        .animation(
                            // Slight overshoot (dampingFraction < 0.7) is intentional — gives the
                            // logo a confident "landing" feel on the branded splash screen.
                            .spring(response: 0.45, dampingFraction: 0.62)
                            .delay(0.10),
                            value: appeared
                        )
                        .brandMark(in: markNamespace)
                }

                // ── Wordmark + tagline ───────────────────────────────────
                VStack(spacing: 8) {
                    Text("Sanchr")
                        .font(SanchrTypography.heroTitle)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .offset(y: appeared ? 0 : 10)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.40).delay(0.50), value: appeared)

                    Text("Encrypted. Synced. Secure.")
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .offset(y: appeared ? 0 : 10)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.40).delay(0.65), value: appeared)
                }
                .padding(.top, 24)

                Spacer()

                // ── Loading indicator ────────────────────────────────────
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.sanchrPrimary)
                    Text("Initializing secure connection...")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }
                .padding(.bottom, 60)
                .offset(y: appeared ? 0 : 10)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.35).delay(0.85), value: appeared)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            appeared = true
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

#Preview {
    SplashView()
}
