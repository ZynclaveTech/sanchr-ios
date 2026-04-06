import Accelerate
import UIKit

/// Self-contained BlurHash encoder/decoder with Accelerate-optimized decode.
/// Same algorithm as woltapp/blurhash and Signal's implementation.
/// 4x3 DCT components → ~30 char base-83 string.
enum BlurHash {

    // MARK: - Public API

    /// Encode a UIImage to a blur hash string.
    static func encode(_ image: UIImage, components: (Int, Int) = (4, 3)) -> String? {
        // Downscale for performance — encoding a 100px image is fast enough
        guard let small = image.preparingThumbnail(of: CGSize(width: 100, height: 100)),
              let cgImage = small.cgImage else {
            guard let cgImage = image.cgImage else { return nil }
            return encodeFromCGImage(cgImage, components: components)
        }
        return encodeFromCGImage(cgImage, components: components)
    }

    /// Decode a blur hash string to a UIImage placeholder.
    static func decode(_ hash: String, width: Int = 32, height: Int = 32) -> UIImage? {
        guard hash.count >= 6 else { return nil }
        let chars = Array(hash)

        let sizeFlag = decode83(chars, from: 0, to: 1)
        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1
        guard hash.count == 4 + 2 * numX * numY else { return nil }

        let quantMaxVal = decode83(chars, from: 1, to: 2)
        let maxVal = Float(quantMaxVal + 1) / 166

        var colors = [(Float, Float, Float)]()
        colors.append(decodeDC(decode83(chars, from: 2, to: 6)))
        for i in 1..<(numX * numY) {
            let s = 4 + i * 2
            colors.append(decodeAC(decode83(chars, from: s, to: s + 2), maximumValue: maxVal))
        }

        // Use Accelerate for fast pixel generation
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis = cos(Float.pi * Float(x) * Float(i) / Float(width)) *
                                    cos(Float.pi * Float(y) * Float(j) / Float(height))
                        let c = colors[j * numX + i]
                        r += c.0 * basis; g += c.1 * basis; b += c.2 * basis
                    }
                }
                let idx = (y * width + x) * 4
                pixels[idx]     = UInt8(clamping: Int(linearToSRGB(r) * 255 + 0.5))
                pixels[idx + 1] = UInt8(clamping: Int(linearToSRGB(g) * 255 + 0.5))
                pixels[idx + 2] = UInt8(clamping: Int(linearToSRGB(b) * 255 + 0.5))
                pixels[idx + 3] = 255
            }
        }

        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Encode internals

    private static func encodeFromCGImage(_ cgImage: CGImage, components: (Int, Int)) -> String? {
        let w = cgImage.width, h = cgImage.height
        let (numX, numY) = components
        guard numX >= 1, numX <= 9, numY >= 1, numY <= 9 else { return nil }

        let bpr = w * 4
        var px = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var factors = [(Float, Float, Float)]()
        for j in 0..<numY {
            for i in 0..<numX {
                factors.append(basisFactor(px: px, w: w, h: h, bpr: bpr, bx: i, by: j))
            }
        }

        let dc = factors[0]
        let ac = Array(factors.dropFirst())

        let sizeFlag = (numX - 1) + (numY - 1) * 9
        var hash = sizeFlag.encode83(length: 1)

        let maxVal: Float
        if ac.isEmpty {
            maxVal = 1; hash += 0.encode83(length: 1)
        } else {
            let actualMax = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max()!
            let qMax = max(0, min(82, Int(floor(actualMax * 166 - 0.5))))
            maxVal = Float(qMax + 1) / 166
            hash += qMax.encode83(length: 1)
        }

        hash += encodeDC(dc).encode83(length: 4)
        for v in ac { hash += encodeAC(v, max: maxVal).encode83(length: 2) }
        return hash
    }

    private static func basisFactor(px: [UInt8], w: Int, h: Int, bpr: Int, bx: Int, by: Int) -> (Float, Float, Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0
        let norm: Float = (bx == 0 && by == 0) ? 1 : 2
        for y in 0..<h {
            for x in 0..<w {
                let basis = norm
                    * cos(Float.pi * Float(bx) * Float(x) / Float(w))
                    * cos(Float.pi * Float(by) * Float(y) / Float(h))
                let i = y * bpr + x * 4
                r += basis * sRGBToLinear(Float(px[i]) / 255)
                g += basis * sRGBToLinear(Float(px[i+1]) / 255)
                b += basis * sRGBToLinear(Float(px[i+2]) / 255)
            }
        }
        let s = 1 / Float(w * h)
        return (r * s, g * s, b * s)
    }

    // MARK: - Color space

    private static func sRGBToLinear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func linearToSRGB(_ v: Float) -> Float { max(0, min(1, v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)) }

    // MARK: - DC / AC encoding

    private static func encodeDC(_ v: (Float, Float, Float)) -> Int {
        (Int(linearToSRGB(v.0) * 255 + 0.5) << 16) + (Int(linearToSRGB(v.1) * 255 + 0.5) << 8) + Int(linearToSRGB(v.2) * 255 + 0.5)
    }
    private static func decodeDC(_ v: Int) -> (Float, Float, Float) {
        (sRGBToLinear(Float(v >> 16) / 255), sRGBToLinear(Float((v >> 8) & 255) / 255), sRGBToLinear(Float(v & 255) / 255))
    }
    private static func encodeAC(_ v: (Float, Float, Float), max m: Float) -> Int {
        func q(_ x: Float) -> Int { max(0, min(18, Int(signPow(x / m, 0.5) * 9 + 9.5))) }
        return q(v.0) * 361 + q(v.1) * 19 + q(v.2)
    }
    private static func decodeAC(_ v: Int, maximumValue m: Float) -> (Float, Float, Float) {
        (signPow((Float(v / 361) - 9) / 9, 2) * m, signPow((Float((v / 19) % 19) - 9) / 9, 2) * m, signPow((Float(v % 19) - 9) / 9, 2) * m)
    }
    private static func signPow(_ v: Float, _ e: Float) -> Float { copysign(pow(abs(v), e), v) }

    // MARK: - Base-83

    private static let b83 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static func decode83(_ c: [Character], from: Int, to: Int) -> Int {
        var v = 0
        for i in from..<min(to, c.count) { if let idx = b83.firstIndex(of: c[i]) { v = v * 83 + idx } }
        return v
    }
}

private extension Int {
    func encode83(length: Int) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
        var r = ""
        for i in 1...length { r.append(chars[(self / Int(pow(83.0, Double(length - i)))) % 83]) }
        return r
    }
}
