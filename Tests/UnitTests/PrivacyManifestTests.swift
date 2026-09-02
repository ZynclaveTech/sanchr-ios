import XCTest
@testable import Sanchr

/// Privacy manifests for every first-party bundle, and the App Store export
/// options. Upload validation (ITMS-91053) rejects a build whose binaries use
/// required-reason APIs without a manifest declaring them, so these tests
/// scan each target's sources for those APIs and check the declared set
/// covers them, then check each *built* bundle actually contains its file.
final class PrivacyManifestTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
    private static let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
    private static let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
    private static let bootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
    private static let keyboard = "NSPrivacyAccessedAPICategoryActiveKeyboards"

    private struct Target {
        let name: String
        let manifest: String
        let sourceDirs: [String]
    }

    private static let targets = [
        Target(name: "Sanchr", manifest: "Resources/PrivacyInfo.xcprivacy",
               sourceDirs: ["App", "Core", "Platform", "Shared", "Features"]),
        Target(name: "SanchrShareExtension", manifest: "SanchrShareExtension/PrivacyInfo.xcprivacy",
               sourceDirs: ["SanchrShareExtension"]),
        Target(name: "SanchrShared", manifest: "SanchrShared/PrivacyInfo.xcprivacy",
               sourceDirs: ["SanchrShared"]),
        Target(name: "LibSignalClient", manifest: "Vendor/LibSignal/Sources/LibSignalClient/PrivacyInfo.xcprivacy",
               sourceDirs: ["Vendor/LibSignal/Sources/LibSignalClient"]),
    ]

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func declaredCategories(_ manifest: [String: Any]) throws -> [String: [String]] {
        let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var out: [String: [String]] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            XCTAssertFalse(reasons.isEmpty, "\(category) needs at least one reason")
            out[category] = reasons
        }
        return out
    }

    /// Categories a target's Swift sources require, by the API names Apple lists.
    private func requiredCategories(in dirs: [String]) throws -> Set<String> {
        let patterns: [(String, [String])] = [
            (Self.userDefaults, ["UserDefaults"]),
            (Self.fileTimestamp, ["attributesOfItem", ".contentModificationDateKey", ".creationDateKey",
                                  "fileModificationDate", "getattrlist", "fstat(", " stat("]),
            (Self.diskSpace, ["volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize"]),
            (Self.bootTime, ["systemUptime", "mach_absolute_time"]),
            (Self.keyboard, ["activeInputModes"]),
        ]
        var required = Set<String>()
        for dir in dirs {
            let base = Self.root.appendingPathComponent(dir)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (category, needles) in patterns where needles.contains(where: text.contains) {
                    required.insert(category)
                }
            }
        }
        return required
    }

    func testEveryTargetDeclaresTheAPIsItsSourcesUse() throws {
        for target in Self.targets {
            let manifest = try plist(target.manifest)
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, target.name)
            XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true, target.name)
            XCTAssertNotNil(manifest["NSPrivacyCollectedDataTypes"] as? [Any], "\(target.name) must declare collected data, even if empty")
            let declared = try declaredCategories(manifest)
            let required = try requiredCategories(in: target.sourceDirs)
            let missing = required.subtracting(declared.keys)
            XCTAssertTrue(missing.isEmpty, "\(target.name) uses \(missing.sorted()) without declaring them")
        }
    }

    func testLibSignalDeclaresTheTimestampAPIItsBinaryLinks() throws {
        // libsignal_ffi.a references fstat, which is on Apple's file-timestamp list.
        let declared = try declaredCategories(try plist("Vendor/LibSignal/Sources/LibSignalClient/PrivacyInfo.xcprivacy"))
        XCTAssertEqual(declared[Self.fileTimestamp], ["C617.1"])
    }

    func testAppDeclaresWhatTheServerReceives() throws {
        let manifest = try plist("Resources/PrivacyInfo.xcprivacy")
        let types = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let names = Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["NSPrivacyCollectedDataTypePhoneNumber", "NSPrivacyCollectedDataTypeContacts",
                                            "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID"]))
        for type in types {
            XCTAssertEqual(type["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        }
        // Message content, names and avatars are end-to-end encrypted and
        // unreadable by the server, so they are not collected.
        XCTAssertFalse(names.contains("NSPrivacyCollectedDataTypeMessages") || names.contains("NSPrivacyCollectedDataTypePhotosorVideos"))
    }

    func testEveryBuiltBundleContainsItsManifest() throws {
        XCTAssertNotNil(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "app")
        for identifier in ["com.sanchr.shared", "com.sanchr.libsignal"] {
            let bundle = try XCTUnwrap(Bundle(identifier: identifier), identifier)
            XCTAssertNotNil(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), identifier)
        }
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let appex = plugins.appendingPathComponent("SanchrShareExtension.appex/PrivacyInfo.xcprivacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appex.path), "share extension")
    }

    func testExportOptionsTargetTheStoreWithProductionICloud() throws {
        let options = try plist("ExportOptions.plist")
        XCTAssertEqual(options["method"] as? String, "app-store-connect")
        XCTAssertEqual(options["iCloudContainerEnvironment"] as? String, "Production")
        XCTAssertEqual(options["signingStyle"] as? String, "automatic")
        let yml = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let team = try XCTUnwrap(options["teamID"] as? String)
        XCTAssertTrue(yml.contains("DEVELOPMENT_TEAM: \(team)"), "export team must match the project team")
    }
}
