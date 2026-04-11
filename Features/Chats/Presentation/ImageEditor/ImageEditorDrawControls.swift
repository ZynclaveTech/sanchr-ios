import SwiftUI

// MARK: - Draw Controls

/// Secondary toolbar shown below the image canvas when the Draw tool is active.
///
/// Contains:
/// - 8 colour swatches (selected swatch has a white ring)
/// - An eraser toggle button (inverted when active)
/// - 3 stroke-width presets rendered as filled dots whose size matches the preset
struct ImageEditorDrawControls: View {

    @Binding var strokeColor: Color
    @Binding var strokeWidth: CGFloat
    @Binding var isErasing: Bool

    private let presetColors: [Color] = [
        .white, .black,
        Color(red: 1,    green: 0.23, blue: 0.19),   // red
        Color(red: 1,    green: 0.58, blue: 0),       // orange
        Color(red: 1,    green: 0.84, blue: 0),       // yellow
        Color(red: 0.2,  green: 0.78, blue: 0.35),    // green
        Color(red: 0,    green: 0.48, blue: 1),        // blue
        Color(red: 0.69, green: 0.32, blue: 0.87),    // purple
    ]

    private let strokePresets: [CGFloat] = [4, 8, 14]

    var body: some View {
        HStack(spacing: 0) {
            // Color swatches
            HStack(spacing: 10) {
                ForEach(presetColors.indices, id: \.self) { i in
                    let color = presetColors[i]
                    let isSelected = !isErasing && strokeColor == color
                    Button {
                        isErasing   = false
                        strokeColor = color
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: isSelected ? 2.5 : 0)
                                    .padding(isSelected ? -1.5 : 0)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    }
                    .animation(.easeInOut(duration: 0.1), value: isSelected)
                }
            }

            Spacer(minLength: 12)

            // Eraser toggle
            Button {
                isErasing.toggle()
            } label: {
                Image(systemName: "eraser.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isErasing ? Color.black : Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        isErasing ? Color.white : Color.white.opacity(0.18),
                        in: Circle()
                    )
            }
            .animation(.easeInOut(duration: 0.1), value: isErasing)

            Spacer(minLength: 12)

            // Stroke width presets
            HStack(spacing: 14) {
                ForEach(strokePresets, id: \.self) { preset in
                    let isSelected = !isErasing && strokeWidth == preset
                    Button {
                        isErasing    = false
                        strokeWidth  = preset
                    } label: {
                        let dotSize = preset * 1.5
                        Circle()
                            .fill(isSelected ? strokeColor : Color.white.opacity(0.55))
                            .frame(width: dotSize, height: dotSize)
                            .frame(width: 32, height: 32)   // fixed tap area
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: isSelected ? 1.5 : 0)
                                    .frame(width: dotSize, height: dotSize)
                            )
                    }
                    .animation(.easeInOut(duration: 0.1), value: isSelected)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}
