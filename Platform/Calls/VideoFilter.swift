import CoreImage

enum VideoFilter: String, CaseIterable, Identifiable, Sendable {
    case none
    case smoothSkin
    case warm
    case cool
    case blackAndWhite
    case vivid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:          return "None"
        case .smoothSkin:    return "Smooth"
        case .warm:          return "Warm"
        case .cool:          return "Cool"
        case .blackAndWhite: return "B&W"
        case .vivid:         return "Vivid"
        }
    }

    /// Returns a configured CIFilter, or nil for .none.
    func makeCIFilter() -> CIFilter? {
        switch self {
        case .none:
            return nil
        case .smoothSkin:
            let f = CIFilter(name: "CIGaussianBlur")!
            f.setValue(1.5, forKey: kCIInputRadiusKey)
            return f
        case .warm:
            let f = CIFilter(name: "CITemperatureAndTint")!
            f.setValue(CIVector(x: 8000, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            return f
        case .cool:
            let f = CIFilter(name: "CITemperatureAndTint")!
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 8000, y: 0), forKey: "inputTargetNeutral")
            return f
        case .blackAndWhite:
            let f = CIFilter(name: "CIColorMonochrome")!
            f.setValue(CIColor.gray, forKey: kCIInputColorKey)
            f.setValue(1.0, forKey: kCIInputIntensityKey)
            return f
        case .vivid:
            let f = CIFilter(name: "CIVibrance")!
            f.setValue(0.5, forKey: kCIInputAmountKey)
            return f
        }
    }
}
