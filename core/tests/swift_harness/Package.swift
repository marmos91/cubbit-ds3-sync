// swift-tools-version: 5.9
// Swift integration test harness for DS3CoreFFI XCFramework.
//
// Prerequisites:
//   1. Build the XCFramework: cd core && ./scripts/build-xcframework.sh
//   2. Set environment variables: DS3_TEST_EMAIL, DS3_TEST_PASSWORD, DS3_TEST_BUCKET
//
// Run:
//   cd core/tests/swift_harness && swift run

import PackageDescription

let package = Package(
    name: "DS3CoreTestHarness",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .binaryTarget(
            name: "DS3CoreFFI",
            path: "../../out/DS3CoreFFI.xcframework"
        ),
        .executableTarget(
            name: "DS3CoreTestHarness",
            dependencies: ["DS3CoreFFI"],
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-import-objc-header", "../../out/Headers/module.modulemap"])
            ]
        )
    ]
)
