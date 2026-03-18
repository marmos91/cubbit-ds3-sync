// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DS3Lib",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [.library(name: "DS3Lib", targets: ["DS3Lib"])],
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
        .testTarget(
            name: "DS3LibTests",
            dependencies: [
                "DS3Lib",
                .product(name: "NIOCore", package: "swift-nio")
            ]
        )
    ]
)
