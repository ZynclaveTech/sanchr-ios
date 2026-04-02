// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Sanchr-iOS",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Sanchr",
            targets: ["Sanchr"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/signalapp/libsignal.git", exact: "0.88.1"),
    ],
    targets: [
        .target(
            name: "Sanchr",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "LibSignalClient", package: "libsignal"),
            ],
            path: ".",
            exclude: ["Tests", "Resources", "Package.swift"]
        ),
        .testTarget(
            name: "SanchrTests",
            dependencies: ["Sanchr"],
            path: "Tests/UnitTests"
        ),
    ]
)
