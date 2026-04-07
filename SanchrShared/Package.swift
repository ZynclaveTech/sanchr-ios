// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SanchrShared",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SanchrShared", targets: ["SanchrShared"]),
    ],
    targets: [
        .target(
            name: "SanchrShared",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
