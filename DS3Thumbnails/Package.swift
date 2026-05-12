// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DS3Thumbnails",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "DS3ThumbnailQueue", targets: ["ThumbnailQueue"]),
        .library(name: "DS3ThumbnailRendering", targets: ["ThumbnailRendering"])
    ],
    dependencies: [
        .package(path: "../DS3Lib")
    ],
    targets: [
        .target(
            name: "ThumbnailQueue",
            dependencies: [
                .product(name: "DS3Lib", package: "DS3Lib")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ThumbnailRendering",
            dependencies: [
                "ThumbnailQueue",
                .product(name: "DS3Lib", package: "DS3Lib")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
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
                .product(name: "DS3Lib", package: "DS3Lib")
            ],
            resources: [.process("Fixtures")]
        )
    ]
)
