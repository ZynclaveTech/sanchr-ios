import Foundation
import SanchrShared
import SwiftUI
import XCTest

@testable import Sanchr

/// No text in the app is a fixed-size system font: it is the design
/// system's face and it scales with Dynamic Type. Symbols and emoji keep
/// their fixed sizes.
final class DynamicTypeSweepTests: XCTestCase {

    func testNoTextUsesAFixedSystemFont() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"\.font\(\.system\(size: [0-9]+"#)
        var offenders: [String] = []
        for dir in ["Features", "App", "Shared", "SanchrShareExtension"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)!
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    let context = lines[max(0, i - 3)...i].joined(separator: "\n")
                    let isSymbol = context.contains("Image(") || context.contains("ProgressView") || context.lowercased().contains("emoji")
                        || url.lastPathComponent.contains("Emoji") || url.lastPathComponent.contains("Sticker")
                    if !isSymbol { offenders.append("\(url.lastPathComponent):\(i + 1)") }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "fixed-size system fonts on text: \(offenders)")
    }

    func testTheScaledHelperExists() throws {
        _ = SanchrTypography.scaled(size: 13, weight: .semibold)
    }
}
