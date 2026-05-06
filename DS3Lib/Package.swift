// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DS3Lib",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "DS3Lib", targets: ["DS3Lib"]),
        .library(name: "DS3ThumbnailQueue", targets: ["ThumbnailQueue"]),
        .library(name: "DS3ThumbnailRendering", targets: ["ThumbnailRendering"])
    ],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto", from: "6.8.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0")
    ],
    targets: [
        .target(
            name: "DS3Lib",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ThumbnailQueue",
            dependencies: ["DS3Lib"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ThumbnailRendering",
            dependencies: ["DS3Lib", "ThumbnailQueue"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DS3LibTests",
            dependencies: [
                "DS3Lib",
                .product(name: "NIOCore", package: "swift-nio")
            ]
        ),
        .testTarget(
            name: "ThumbnailQueueTests",
            dependencies: ["ThumbnailQueue"]
        ),
        .testTarget(
            name: "ThumbnailRenderingTests",
            dependencies: [
                "ThumbnailRendering",
                "ThumbnailQueue",
                "DS3Lib"
            ],
            resources: [.process("Fixtures")]
        )
    ]
)
