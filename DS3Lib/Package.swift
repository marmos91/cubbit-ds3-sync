// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DS3Lib",
    platforms: [.macOS(.v15)],
    products: [.library(name: "DS3Lib", targets: ["DS3Lib"])],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto", from: "6.8.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "DS3Lib", dependencies: [
            .product(name: "SotoS3", package: "soto"),
            .product(name: "Atomics", package: "swift-atomics"),
        ]),
        .testTarget(name: "DS3LibTests", dependencies: ["DS3Lib"]),
    ]
)
