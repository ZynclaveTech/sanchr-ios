import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// CIFilter-based QR code generator with optional center logo overlay.
/// Uses "H" error correction (30% redundancy) so a small center logo
/// does not degrade scan reliability.
public enum QRCodeGenerator {
    /// Generate a QR code image from a string, optionally compositing
    /// a logo in the center with a white rounded-rect backing.
    ///
    /// - Parameters:
    ///   - string: The data to encode (URL, text, etc.).
    ///   - size: Output image dimension in points (square).
    ///   - logoImage: Optional logo to place at the QR center.
    ///   - logoSizeFraction: Logo size as a fraction of `size` (default 0.18).
    /// - Returns: A rendered `UIImage`, or `nil` on failure.
    public static func generate(
        from string: String,
        size: CGFloat = 200,
        logoImage: UIImage? = nil,
        logoSizeFraction: CGFloat = 0.18
    ) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"  // 30% redundancy -- safe for center logo

        guard let outputImage = filter.outputImage else { return nil }

        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let scaledImage = outputImage.transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent)
        else { return nil }

        var qrImage = UIImage(cgImage: cgImage)

        if let logo = logoImage {
            let logoSize = size * logoSizeFraction
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: size, height: size)
            )
            qrImage = renderer.image { _ in
                qrImage.draw(
                    in: CGRect(origin: .zero, size: CGSize(width: size, height: size))
                )
                // White rounded-rect backing behind the logo
                let logoBgRect = CGRect(
                    x: (size - logoSize - 8) / 2,
                    y: (size - logoSize - 8) / 2,
                    width: logoSize + 8,
                    height: logoSize + 8
                )
                UIColor.white.setFill()
                UIBezierPath(roundedRect: logoBgRect, cornerRadius: logoSize * 0.22).fill()
                // Logo itself
                let logoRect = CGRect(
                    x: (size - logoSize) / 2,
                    y: (size - logoSize) / 2,
                    width: logoSize,
                    height: logoSize
                )
                logo.draw(in: logoRect)
            }
        }
        return qrImage
    }
}
