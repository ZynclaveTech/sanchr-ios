import Foundation
import PencilKit
import SwiftUI

// MARK: - State

/// Central state model for the image editor.
///
/// Rotation and flip are applied immediately by mutating `currentImage` so
/// that all tool operations (draw, crop) always work in the current visual
/// coordinate space with no deferred transform math.
@Observable
final class ImageEditorState {

    // MARK: - Tool

    enum Tool: CaseIterable, Equatable {
        case draw, crop, rotate

        var icon: String {
            switch self {
            case .draw: return "pencil.tip"
            case .crop: return "crop"
            case .rotate: return "rotate.right"
            }
        }
        var label: String {
            switch self {
            case .draw: return "Draw"
            case .crop: return "Crop"
            case .rotate: return "Rotate"
            }
        }
    }

    // MARK: - Crop Aspect

    enum CropAspect: String, CaseIterable {
        case free = "Free"
        case original = "Original"
        case square = "1:1"
        case widescreen = "16:9"
        case fourThree = "4:3"
    }

    // MARK: - Properties

    /// The working image. Mutated in-place by rotate / flip so that all
    /// subsequent draw and crop operations are always in the current
    /// visual orientation.
    var currentImage: UIImage

    var activeTool: Tool? = nil

    // Draw
    var drawing = PKDrawing()
    var strokeColor: Color = .white
    var strokeWidth: CGFloat = 8
    var isErasing = false

    // Crop — normalised to [0, 1] relative to the displayed image frame.
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: - Init

    init(image: UIImage) {
        self.currentImage = image
    }

    // MARK: - Rotate / Flip

    /// Rotate 90° clockwise. Clears drawing and resets crop because the image
    /// dimensions may have swapped.
    func rotateRight() {
        let src = currentImage
        let size = src.size
        let newSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        currentImage = UIGraphicsImageRenderer(size: newSize, format: format).image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: .pi / 2)
            src.draw(
                in: CGRect(
                    x: -size.width / 2, y: -size.height / 2,
                    width: size.width, height: size.height))
        }
        drawing = PKDrawing()
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Mirror horizontally. Clears drawing to avoid mirrored strokes.
    func flipHorizontal() {
        let src = currentImage
        let size = src.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        currentImage = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: size.width, y: 0)
            ctx.cgContext.scaleBy(x: -1, y: 1)
            src.draw(in: CGRect(origin: .zero, size: size))
        }
        drawing = PKDrawing()
    }

    // MARK: - Crop helpers

    func resetCrop() {
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func applyCropAspect(_ aspect: CropAspect) {
        let imageAR = currentImage.size.width / currentImage.size.height
        switch aspect {
        case .free, .original:
            resetCrop()
        case .square:
            applyTargetAR(1, imageAR: imageAR)
        case .widescreen:
            applyTargetAR(16 / 9, imageAR: imageAR)
        case .fourThree:
            applyTargetAR(4 / 3, imageAR: imageAR)
        }
    }

    private func applyTargetAR(_ targetAR: CGFloat, imageAR: CGFloat) {
        if targetAR > imageAR {
            let h = imageAR / targetAR
            cropRect = CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        } else {
            let w = targetAR / imageAR
            cropRect = CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
    }

    // MARK: - Render

    /// Composite drawing on top of the image and apply crop.
    ///
    /// - Parameter canvasSize: The displayed size of the image in points
    ///   (the PKCanvasView frame). Needed to scale drawing strokes to full
    ///   image resolution.
    func render(canvasSize: CGSize) -> UIImage {
        let image = currentImage
        let imageSize = image.size

        // 1. Flatten drawing at full image resolution.
        let drawingScale = imageSize.width / max(canvasSize.width, 1)
        let drawingImage = drawing.image(
            from: CGRect(origin: .zero, size: canvasSize),
            scale: drawingScale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let withDrawing = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
            image.draw(at: .zero)
            drawingImage.draw(in: CGRect(origin: .zero, size: imageSize))
        }

        // 2. Apply crop.
        let noCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard cropRect != noCrop, let cgImage = withDrawing.cgImage else {
            return withDrawing
        }
        let px = CGRect(
            x: cropRect.minX * withDrawing.size.width,
            y: cropRect.minY * withDrawing.size.height,
            width: cropRect.width * withDrawing.size.width,
            height: cropRect.height * withDrawing.size.height
        )
        guard let cropped = cgImage.cropping(to: px) else { return withDrawing }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}
