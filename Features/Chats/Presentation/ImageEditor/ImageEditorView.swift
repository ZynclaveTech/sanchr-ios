import PencilKit
import SanchrShared
import SwiftUI

// MARK: - Main Editor View

/// Full-screen image editor presented before the send caption screen.
///
/// Tools:
/// - **Draw** — PencilKit canvas with colour swatches, stroke-width presets and eraser.
/// - **Crop** — Draggable corner handles with rule-of-thirds grid and aspect-ratio pills.
/// - **Rotate** — 90° CW rotation and horizontal flip applied immediately.
///
/// Calling `onComplete` produces a single `UIImage` with all edits composited
/// at the original image resolution. `onCancel` discards all changes.
struct ImageEditorView: View {

    let sourceImage: UIImage
    let onComplete: (UIImage) -> Void
    let onCancel:   () -> Void

    @State private var state: ImageEditorState
    /// Size of the displayed (fitted) image in points — used to scale PencilKit
    /// strokes back to full resolution at render time.
    @State private var canvasSize: CGSize = .zero

    init(
        sourceImage: UIImage,
        onComplete: @escaping (UIImage) -> Void,
        onCancel:   @escaping () -> Void
    ) {
        self.sourceImage = sourceImage
        self.onComplete  = onComplete
        self.onCancel    = onCancel
        _state = State(initialValue: ImageEditorState(image: sourceImage))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                imageCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomSection
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .font(.system(size: 16))
                .foregroundStyle(.white)

            Spacer()

            // Undo last stroke
            Button {
                guard !state.drawing.strokes.isEmpty else { return }
                var d = state.drawing
                var strokes = d.strokes
                strokes.removeLast()
                d = PKDrawing(strokes: strokes)
                state.drawing = d
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .opacity(state.drawing.strokes.isEmpty ? 0.3 : 1)
            .accessibilityLabel("Undo stroke")

            Spacer()

            Button("Done") {
                guard canvasSize != .zero else { onComplete(state.currentImage); return }
                onComplete(state.render(canvasSize: canvasSize))
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(SanchrColors.primary)
        }
    }

    // MARK: - Image Canvas

    private var imageCanvas: some View {
        GeometryReader { geo in
            let frame = fittedFrame(imageSize: state.currentImage.size, in: geo.size)

            ZStack {
                // ① Source image (never receives touch)
                Image(uiImage: state.currentImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: frame.width, height: frame.height)
                    .allowsHitTesting(false)

                // ② PencilKit canvas — exact same size / position as the image
                if state.activeTool == .draw {
                    PKDrawingCanvasView(drawing: $state.drawing)
                        .frame(width: frame.width, height: frame.height)
                        .background(Color.clear)
                        .transition(.opacity)
                }

                // ③ Crop overlay — fills the full canvas so it can dim letterbox areas
                if state.activeTool == .crop {
                    ImageEditorCropOverlay(
                        cropRect:   $state.cropRect,
                        imageFrame: frame,
                        onAspect:   { state.applyCropAspect($0) }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.2), value: state.activeTool)
            .onAppear {
                canvasSize = CGSize(width: frame.width, height: frame.height)
            }
            .onChange(of: geo.size) { _, newSize in
                let f = fittedFrame(imageSize: state.currentImage.size, in: newSize)
                canvasSize = CGSize(width: f.width, height: f.height)
            }
            .onChange(of: state.currentImage.size) { _, _ in
                let f = fittedFrame(imageSize: state.currentImage.size, in: geo.size)
                canvasSize = CGSize(width: f.width, height: f.height)
            }
        }
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 14) {
            // Secondary controls for the active tool
            Group {
                switch state.activeTool {
                case .rotate:
                    rotateControls
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                default:
                    EmptyView()
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.activeTool)

            // Primary tool selector tabs
            toolSelector
        }
    }

    // MARK: - Rotate Sub-Controls

    private var rotateControls: some View {
        HStack(spacing: 12) {
            rotateButton(
                title: "Rotate",
                icon:  "rotate.right",
                action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        state.rotateRight()
                    }
                }
            )
            rotateButton(
                title: "Flip",
                icon:  "arrow.left.and.right.righttriangle.left.righttriangle.right",
                action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        state.flipHorizontal()
                    }
                }
            )
        }
    }

    private func rotateButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Tool Selector

    private var toolSelector: some View {
        HStack(spacing: 0) {
            ForEach(ImageEditorState.Tool.allCases, id: \.self) { tool in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        state.activeTool = state.activeTool == tool ? nil : tool
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 20, weight: .medium))
                        Text(tool.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(state.activeTool == tool ? Color.black : Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        state.activeTool == tool ? Color.white : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
            }
        }
        .padding(4)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Geometry Helper

    private func fittedFrame(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0,
              imageSize.width > 0,     imageSize.height > 0 else { return .zero }
        let scale = min(
            containerSize.width  / imageSize.width,
            containerSize.height / imageSize.height
        )
        let w = imageSize.width  * scale
        let h = imageSize.height * scale
        return CGRect(
            x: (containerSize.width  - w) / 2,
            y: (containerSize.height - h) / 2,
            width: w, height: h
        )
    }
}

// MARK: - PencilKit Canvas (UIViewRepresentable)

/// UIViewRepresentable wrapper for `PKCanvasView`, driven by the system
/// `PKToolPicker`.
///
/// The canvas is transparent and sized to match the displayed image so strokes
/// render exactly over the image content. Tools come from Apple's own palette
/// rather than a bespoke row of swatches: it brings pen, pencil, marker,
/// eraser, lasso, ruler, the full colour picker and undo/redo, and it is what
/// people already know from Notes and Markup.
private struct PKDrawingCanvasView: UIViewRepresentable {

    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawing = drawing
        // Finger as well as Pencil: most people editing a chat photo have no
        // Apple Pencil to hand.
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        context.coordinator.attachToolPicker(to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.detachToolPicker(from: canvas)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PKDrawingCanvasView
        private let toolPicker = PKToolPicker()

        init(_ parent: PKDrawingCanvasView) { self.parent = parent }

        /// The picker only appears for a first responder, so the canvas has to
        /// be made one — without it the palette silently never shows.
        func attachToolPicker(to canvas: PKCanvasView) {
            toolPicker.setVisible(true, forFirstResponder: canvas)
            toolPicker.addObserver(canvas)
            DispatchQueue.main.async { canvas.becomeFirstResponder() }
        }

        func detachToolPicker(from canvas: PKCanvasView) {
            toolPicker.setVisible(false, forFirstResponder: canvas)
            toolPicker.removeObserver(canvas)
            canvas.resignFirstResponder()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
