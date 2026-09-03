import CoreImage
import SanchrShared
import UIKit
import XCTest

/// The brand mark is a transparent bird-and-S drawn on the screen's own
/// ground. The old asset was an opaque tile, so call sites clipped it to a
/// rounded square and the splash painted a fixed navy under it; both
/// would cut or clash with the transparent mark.
final class BrandMarkTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private static let logoSites = [
        "Features/Auth/Presentation/LoginView.swift",
        "Features/Auth/Presentation/SplashView.swift",
        "Features/Contacts/Presentation/ContactSyncView.swift",
        "SanchrShared/DesignSystem/LockScreenView.swift",
        "SanchrShared/DesignSystem/ExportComponents.swift",
    ]

    func testTheMarkIsNeverClippedToATile() throws {
        for site in Self.logoSites {
            let source = try text(site)
            var search = source.startIndex
            while let use = source.range(of: "Image(\"SanchrLogo\")", range: search..<source.endIndex) {
                let after = String(source[use.upperBound...].prefix(320))
                XCTAssertFalse(after.contains(".clipShape("), "\(site) clips the transparent mark to a tile")
                XCTAssertFalse(after.contains(".blendMode("), "\(site) blends the mark as if the ground were always dark")
                search = use.upperBound
            }
        }
    }

    func testSplashFollowsTheAppearance() throws {
        let splash = try text("Features/Auth/Presentation/SplashView.swift")
        XCTAssertTrue(splash.contains("SanchrExportColors.background"), "the splash paints the same ground as every screen")
        XCTAssertFalse(splash.contains("0x08080E"), "a fixed navy ground ignored the light theme")
        XCTAssertFalse(splash.contains(".preferredColorScheme(.dark)"))
    }

    func testLaunchColourHasBothAppearances() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Assets.xcassets/LaunchBackground.colorset/Contents.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        func components(dark: Bool) -> [String: String]? {
            colors.first { entry in
                let appearances = entry["appearances"] as? [[String: String]] ?? []
                return appearances.contains { $0["value"] == "dark" } == dark
            }.flatMap { ($0["color"] as? [String: Any])?["components"] as? [String: String] }
        }
        let light = try XCTUnwrap(components(dark: false)), dark = try XCTUnwrap(components(dark: true))
        XCTAssertEqual([light["red"], light["green"], light["blue"]], ["0xFF", "0xFF", "0xFF"], "light launch matches systemBackground")
        XCTAssertEqual([dark["red"], dark["green"], dark["blue"]], ["0x00", "0x00", "0x00"], "dark launch matches systemBackground")
    }

    func testLogoAssetIsTransparentAtEveryScale() throws {
        let set = Self.root.appendingPathComponent("Resources/BrandAssets.xcassets/SanchrLogo.imageset")
        for (scale, side) in [(1, 128), (2, 256), (3, 384)] {
            let png = try Data(contentsOf: set.appendingPathComponent("logo@\(scale)x.png"))
            func be32(_ offset: Int) -> Int { png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
            XCTAssertEqual(be32(16), side, "logo@\(scale)x width")
            XCTAssertEqual(be32(20), side, "logo@\(scale)x height")
            XCTAssertEqual(png[25], 6, "logo@\(scale)x must be RGBA: the mark sits on the screen's own ground")
        }
    }

    func testProfileQRCarriesTheRealMark() throws {
        let profile = try text("Features/Profile/Presentation/ProfileView.swift")
        XCTAssertTrue(profile.contains("logoImage: UIImage(named: \"SanchrLogo\")"))
        XCTAssertFalse(profile.contains("sanchrLogoMark"), "the drawn gradient S stood in for the mark")
    }

    func testQRStillDecodesUnderTheMark() throws {
        let link = "https://sanchr.com/u/0123456789abcdef"
        let logo = try XCTUnwrap(UIImage(named: "SanchrLogo"))
        let qr = try XCTUnwrap(QRCodeGenerator.generate(from: link, size: 190, logoImage: logo, logoSizeFraction: 0.22))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(image: qr)!).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(features.first?.messageString, link, "the centre mark must stay inside the 30% the H level can recover")
    }
}

