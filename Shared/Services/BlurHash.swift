import UIKit

/// Lightweight BlurHash encoder/decoder.
/// Encodes an image into a ~30 character string for instant placeholder display.
enum BlurHash {

    // MARK: - Encode

    /// Encode a UIImage to a blur hash string. Components: 4 wide x 3 tall.
    static func encode(_ image: UIImage, components: (Int, Int) = (4, 3)) -> String? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let (numX, numY) = components

        guard numX >= 1, numX <= 9, numY >= 1, numY <= 9 else { return nil }

        // Get pixel data
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Compute DCT factors
        var factors = [(Float, Float, Float)]()
        for j in 0..<numY {
            for i in 0..<numX {
                let factor = multiplyBasisFunction(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow, basisX: i, basisY: j)
                factors.append(factor)
            }
        }

        // Encode
        let dc = factors.first!
        let ac = Array(factors.dropFirst())

        let sizeFlag = (numX - 1) + (numY - 1) * 9
        var hash = sizeFlag.encode83(length: 1)

        let maximumValue: Float
        if ac.isEmpty {
            maximumValue = 1
            hash += 0.encode83(length: 1)
        } else {
            let actualMaximum = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max()!
            let quantisedMaximum = max(0, min(82, Int(floor(actualMaximum * 166 - 0.5))))
            maximumValue = Float(quantisedMaximum + 1) / 166
            hash += quantisedMaximum.encode83(length: 1)
        }

        hash += encodeDC(dc).encode83(length: 4)

        for acValue in ac {
            hash += encodeAC(acValue, maximumValue: maximumValue).encode83(length: 2)
        }

        return hash
    }

    // MARK: - Decode

    /// Decode a blur hash string to a UIImage.
    static func decode(_ hash: String, width: Int = 32, height: Int = 32) -> UIImage? {
        guard hash.count >= 6 else { return nil }
        let chars = Array(hash)

        let sizeFlag = decode83(chars, from: 0, to: 1)
        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1

        let quantisedMaximumValue = decode83(chars, from: 1, to: 2)
        let maximumValue = Float(quantisedMaximumValue + 1) / 166

        var colors = [(Float, Float, Float)]()
        colors.append(decodeDC(decode83(chars, from: 2, to: 6)))

        for i in 1..<(numX * numY) {
            let start = 4 + i * 2
            let value = decode83(chars, from: start, to: start + 2)
            colors.append(decodeAC(value, maximumValue: maximumValue))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis = cos(Float.pi * Float(x) * Float(i) / Float(width)) *
                                    cos(Float.pi * Float(y) * Float(j) / Float(height))
                        let color = colors[j * numX + i]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let idx = (y * width + x) * 4
                pixels[idx] = UInt8(clamping: Int(linearToSRGB(r) * 255))
                pixels[idx + 1] = UInt8(clamping: Int(linearToSRGB(g) * 255))
                pixels[idx + 2] = UInt8(clamping: Int(linearToSRGB(b) * 255))
                pixels[idx + 3] = 255
            }
        }

        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return nil }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - Internals

    private static func multiplyBasisFunction(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int, basisX: Int, basisY: Int) -> (Float, Float, Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0
        let normalisation: Float = basisX == 0 && basisY == 0 ? 1 : 2
        for y in 0..<height {
            for x in 0..<width {
                let basis = normalisation
                    * cos(Float.pi * Float(basisX) * Float(x) / Float(width))
                    * cos(Float.pi * Float(basisY) * Float(y) / Float(height))
                let idx = y * bytesPerRow + x * 4
                r += basis * sRGBToLinear(Float(pixels[idx]) / 255)
                g += basis * sRGBToLinear(Float(pixels[idx + 1]) / 255)
                b += basis * sRGBToLinear(Float(pixels[idx + 2]) / 255)
            }
        }
        let scale = 1 / Float(width * height)
        return (r * scale, g * scale, b * scale)
    }

    private static func sRGBToLinear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func linearToSRGB(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    private static func encodeDC(_ value: (Float, Float, Float)) -> Int {
        let r = Int(max(0, min(255, linearToSRGB(value.0) * 255 + 0.5)))
        let g = Int(max(0, min(255, linearToSRGB(value.1) * 255 + 0.5)))
        let b = Int(max(0, min(255, linearToSRGB(value.2) * 255 + 0.5)))
        return (r << 16) + (g << 8) + b
    }

    private static func decodeDC(_ value: Int) -> (Float, Float, Float) {
        let r = value >> 16
        let g = (value >> 8) & 255
        let b = value & 255
        return (sRGBToLinear(Float(r) / 255), sRGBToLinear(Float(g) / 255), sRGBToLinear(Float(b) / 255))
    }

    private static func encodeAC(_ value: (Float, Float, Float), maximumValue: Float) -> Int {
        func quantise(_ v: Float) -> Int { max(0, min(18, Int(floor(signPow(v / maximumValue, 0.5) * 9 + 9.5)))) }
        return quantise(value.0) * 19 * 19 + quantise(value.1) * 19 + quantise(value.2)
    }

    private static func decodeAC(_ value: Int, maximumValue: Float) -> (Float, Float, Float) {
        let quantR = value / (19 * 19)
        let quantG = (value / 19) % 19
        let quantB = value % 19
        return (
            signPow((Float(quantR) - 9) / 9, 2) * maximumValue,
            signPow((Float(quantG) - 9) / 9, 2) * maximumValue,
            signPow((Float(quantB) - 9) / 9, 2) * maximumValue
        )
    }

    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        copysign(pow(abs(value), exp), value)
    }

    private static let base83Chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    private static func decode83(_ chars: [Character], from: Int, to: Int) -> Int {
        var value = 0
        for i in from..<min(to, chars.count) {
            if let idx = base83Chars.firstIndex(of: chars[i]) {
                value = value * 83 + idx
            }
        }
        return value
    }
}

private extension Int {
    func encode83(length: Int) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
        var result = ""
        for i in 1...length {
            let digit = (self / Int(pow(83.0, Double(length - i)))) % 83
            result.append(chars[digit])
        }
        return result
    }
}
