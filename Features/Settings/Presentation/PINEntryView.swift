import SwiftUI
import SanchrShared

// MARK: - PINEntryView

/// Full-screen numeric PIN entry with 6 dot indicators and a custom keypad.
///
/// Callers supply:
/// - `title` / `subtitle` — contextual copy shown above the dots
/// - `onComplete` — called with the entered 6-digit string
/// - `onCancel` — called when the user taps Back/Cancel
struct PINEntryView: View {

    let title: String
    let subtitle: String
    let isConfirmation: Bool
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    @State private var digits: [Int] = []
    @State private var shakeOffset: CGFloat = 0

    private let maxLength = 6

    var body: some View {
        ZStack {
            SanchrExportColors.surfaceSoft.ignoresSafeArea()

            VStack(spacing: 0) {
                // Back button row
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()

                // Title + subtitle
                VStack(spacing: 8) {
                    Text(title)
                        .font(SanchrTypography.sectionHeader)
                        .fontWeight(.bold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(SanchrTypography.body)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer().frame(height: 40)

                // Dot indicators
                HStack(spacing: 18) {
                    ForEach(0 ..< maxLength, id: \.self) { idx in
                        Circle()
                            .fill(idx < digits.count ? SanchrColors.primary : SanchrExportColors.line)
                            .frame(width: 14, height: 14)
                            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: digits.count)
                    }
                }
                .offset(x: shakeOffset)

                Spacer()

                // Custom numeric keypad
                numericKeypad
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Keypad

    private var numericKeypad: some View {
        let keys: [[String]] = [
            ["1", "2", "3"],
            ["4", "5", "6"],
            ["7", "8", "9"],
            ["", "0", "⌫"],
        ]

        return VStack(spacing: 16) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key == "" {
            Color.clear
                .frame(width: keySize, height: keySize)
        } else if key == "⌫" {
            Button {
                deleteLastDigit()
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .frame(width: keySize, height: keySize)
                    .background(SanchrExportColors.surface, in: Circle())
            }
        } else {
            Button {
                if let digit = Int(key) {
                    appendDigit(digit)
                } else {
                    SanchrLogger.app.error("PINEntryView: Invalid key '\(key)' parsed as non-digit")
                }
            } label: {
                Text(key)
                    .font(.system(size: 28, weight: .regular, design: .rounded))
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .frame(width: keySize, height: keySize)
                    .background(SanchrExportColors.surface, in: Circle())
            }
        }
    }

    private var keySize: CGFloat { 78 }

    // MARK: - Input Handling

    private func appendDigit(_ digit: Int) {
        guard digits.count < maxLength else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        digits.append(digit)
        if digits.count == maxLength {
            let pin = digits.map { String($0) }.joined()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                onComplete(pin)
            }
        }
    }

    private func deleteLastDigit() {
        guard !digits.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        digits.removeLast()
    }

    /// Shake animation + clear — used by parent on PIN mismatch.
    func triggerError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.default) {
            shakeOffset = 12
        }
        withAnimation(.default.delay(0.05)) {
            shakeOffset = -12
        }
        withAnimation(.default.delay(0.1)) {
            shakeOffset = 8
        }
        withAnimation(.default.delay(0.15)) {
            shakeOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            digits = []
        }
    }
}
