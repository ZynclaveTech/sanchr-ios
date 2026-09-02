import SanchrShared
import SwiftUI

// MARK: - Crop Overlay

/// Transparent overlay that fills the entire editor canvas and renders:
///
/// - A semi-opaque dim mask outside the current crop rect
/// - A 1-pt white border around the crop rect
/// - A rule-of-thirds grid (visible while actively dragging a handle)
/// - Draggable corner handles at all four corners
/// - Aspect-ratio pill buttons anchored at the bottom
///
/// `cropRect` is normalised to [0, 1] × [0, 1] **relative to `imageFrame`**,
/// not relative to the full canvas. `imageFrame` is the position and size of
/// the displayed image in the full-canvas coordinate space (from the parent
/// `GeometryReader`).
struct ImageEditorCropOverlay: View {

    @Binding var cropRect: CGRect
    /// Position and size of the displayed image within the full editor canvas.
    let imageFrame: CGRect
    let onAspect: (ImageEditorState.CropAspect) -> Void

    @State private var isDragging = false
    /// Crop rect captured at the start of each handle drag so we apply the
    /// **total** DragGesture translation rather than incremental deltas,
    /// avoiding accumulated floating-point drift.
    @State private var dragStartRect: CGRect = .zero

    private let minCropPoints: CGFloat = 44  // minimum crop dimension in canvas points

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let screenRect = cropScreenRect(canvasSize: geo.size)

            ZStack {
                dimMask(canvasSize: geo.size, cropScreenRect: screenRect)
                    .allowsHitTesting(false)

                if isDragging {
                    gridLines(in: screenRect)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                cropBorder(in: screenRect)
                    .allowsHitTesting(false)

                // Interior drag: moves the whole crop region. Only the corners
                // were interactive before, so a crop could be resized but never
                // repositioned — to frame a subject off-centre you had to drag
                // two opposite corners and hope.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartRect = cropRect
                                }
                                cropRect = moved(
                                    startRect: dragStartRect,
                                    totalDelta: value.translation
                                )
                            }
                            .onEnded { _ in isDragging = false }
                    )

                cornerHandles(canvasSize: geo.size)

                // Aspect-ratio pills pinned to the bottom of the canvas
                VStack {
                    Spacer()
                    aspectPills
                        .padding(.bottom, 12)
                }
                .allowsHitTesting(true)
            }
            .animation(.easeInOut(duration: 0.12), value: isDragging)
        }
    }

    // MARK: - Dim Mask (Canvas + Hole)

    private func dimMask(canvasSize: CGSize, cropScreenRect: CGRect) -> some View {
        Canvas { context, size in
            // Fill the whole canvas with the dim colour, then punch out the crop hole.
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(cropScreenRect)
            context.fill(path, with: .color(.black.opacity(0.6)),
                         style: FillStyle(eoFill: true))
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    // MARK: - Rule-of-Thirds Grid

    private func gridLines(in rect: CGRect) -> some View {
        Canvas { context, _ in
            let color = Color.white.opacity(0.35)
            let style = StrokeStyle(lineWidth: 0.6)

            for i in 1...2 {
                let y = rect.minY + rect.height * CGFloat(i) / 3
                var p = Path()
                p.move(to: CGPoint(x: rect.minX, y: y))
                p.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(p, with: .color(color), style: style)

                let x = rect.minX + rect.width * CGFloat(i) / 3
                var q = Path()
                q.move(to: CGPoint(x: x, y: rect.minY))
                q.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(q, with: .color(color), style: style)
            }
        }
    }

    // MARK: - Crop Border

    private func cropBorder(in rect: CGRect) -> some View {
        Rectangle()
            .stroke(Color.white, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Corner Handles

    private func cornerHandles(canvasSize: CGSize) -> some View {
        let sr = cropScreenRect(canvasSize: canvasSize)
        return ForEach(CropCorner.allCases, id: \.self) { corner in
            CornerHandleView(
                position: corner.point(in: sr),
                corner: corner
            ) { phase, translation in
                handleDrag(phase: phase, translation: translation,
                           corner: corner, canvasSize: canvasSize)
            }
        }
    }

    // MARK: - Aspect-Ratio Pills

    private var aspectPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ImageEditorState.CropAspect.allCases, id: \.self) { aspect in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            onAspect(aspect)
                        }
                    } label: {
                        Text(aspect.rawValue)
                            .font(SanchrTypography.scaled(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Drag Logic

    private func handleDrag(
        phase: DragPhase,
        translation: CGSize,
        corner: CropCorner,
        canvasSize: CGSize
    ) {
        switch phase {
        case .began:
            isDragging    = true
            dragStartRect = cropRect
        case .changed:
            cropRect = adjusted(startRect: dragStartRect, corner: corner,
                                totalDelta: translation, canvasSize: canvasSize)
        case .ended:
            isDragging = false
        }
    }

    private func adjusted(
        startRect:  CGRect,
        corner:     CropCorner,
        totalDelta: CGSize,
        canvasSize: CGSize
    ) -> CGRect {
        // Convert canvas-point delta → normalised delta relative to imageFrame
        let dx = totalDelta.width  / imageFrame.width
        let dy = totalDelta.height / imageFrame.height
        let minW = minCropPoints / imageFrame.width
        let minH = minCropPoints / imageFrame.height

        var r = startRect
        switch corner {
        case .topLeft:
            let nx = max(0, min(r.maxX - minW, r.minX + dx))
            let ny = max(0, min(r.maxY - minH, r.minY + dy))
            r = CGRect(x: nx, y: ny, width: r.maxX - nx, height: r.maxY - ny)
        case .topRight:
            let nx = min(1, max(r.minX + minW, r.maxX + dx))
            let ny = max(0, min(r.maxY - minH, r.minY + dy))
            r = CGRect(x: r.minX, y: ny, width: nx - r.minX, height: r.maxY - ny)
        case .bottomLeft:
            let nx = max(0, min(r.maxX - minW, r.minX + dx))
            let ny = min(1, max(r.minY + minH, r.maxY + dy))
            r = CGRect(x: nx, y: r.minY, width: r.maxX - nx, height: ny - r.minY)
        case .bottomRight:
            let nx = min(1, max(r.minX + minW, r.maxX + dx))
            let ny = min(1, max(r.minY + minH, r.maxY + dy))
            r = CGRect(x: r.minX, y: r.minY, width: nx - r.minX, height: ny - r.minY)
        }
        return r
    }

    /// Slides the crop rect by a drag, keeping its size and clamping it inside
    /// the image rather than letting it walk off the edge.
    func moved(startRect: CGRect, totalDelta: CGSize) -> CGRect {
        let dx = totalDelta.width / imageFrame.width
        let dy = totalDelta.height / imageFrame.height
        return CGRect(
            x: min(max(0, startRect.minX + dx), 1 - startRect.width),
            y: min(max(0, startRect.minY + dy), 1 - startRect.height),
            width: startRect.width,
            height: startRect.height
        )
    }

    // MARK: - Coordinate Helpers

    /// Convert the normalised `cropRect` to a `CGRect` in the full canvas
    /// coordinate space (same space as `imageFrame`).
    private func cropScreenRect(canvasSize: CGSize) -> CGRect {
        _ = canvasSize  // canvasSize unused; coords are in imageFrame space
        return CGRect(
            x: imageFrame.minX + cropRect.minX * imageFrame.width,
            y: imageFrame.minY + cropRect.minY * imageFrame.height,
            width:  cropRect.width  * imageFrame.width,
            height: cropRect.height * imageFrame.height
        )
    }
}

// MARK: - Corner Enum

private enum CropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Direction multipliers for drawing the L-shaped handle indicator.
    var lDirections: (h: CGFloat, v: CGFloat) {
        switch self {
        case .topLeft:     return ( 1,  1)
        case .topRight:    return (-1,  1)
        case .bottomLeft:  return ( 1, -1)
        case .bottomRight: return (-1, -1)
        }
    }
}

// MARK: - Drag Phase

private enum DragPhase { case began, changed, ended }

// MARK: - Corner Handle View

private struct CornerHandleView: View {

    let position: CGPoint
    let corner:   CropCorner
    let onGesture: (_ phase: DragPhase, _ translation: CGSize) -> Void

    @State private var gestureActive = false

    private let lineLen:    CGFloat = 16
    private let lineWidth:  CGFloat = 3
    private let touchArea:  CGFloat = 44

    var body: some View {
        Canvas { context, size in
            let cx = size.width  / 2
            let cy = size.height / 2
            let (hDir, vDir) = corner.lDirections

            var hPath = Path()
            hPath.move(to: CGPoint(x: cx, y: cy))
            hPath.addLine(to: CGPoint(x: cx + hDir * lineLen, y: cy))
            context.stroke(hPath, with: .color(.white),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            var vPath = Path()
            vPath.move(to: CGPoint(x: cx, y: cy))
            vPath.addLine(to: CGPoint(x: cx, y: cy + vDir * lineLen))
            context.stroke(vPath, with: .color(.white),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .frame(width: touchArea, height: touchArea)
        .contentShape(Rectangle())
        .position(position)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !gestureActive {
                        gestureActive = true
                        onGesture(.began, .zero)
                    }
                    onGesture(.changed, value.translation)
                }
                .onEnded { value in
                    gestureActive = false
                    onGesture(.changed, value.translation)
                    onGesture(.ended, .zero)
                }
        )
    }
}
