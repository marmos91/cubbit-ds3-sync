// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DS3Lib",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "DS3Lib", targets: ["DS3Lib"]),
        .library(name: "DS3CoreFFI", targets: ["DS3CoreFFI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        // swift-nio retained solely for `NIOCore.ByteBuffer` in
        // `DS3LibTests/StreamingIOTests.swift` (IEXT-03 streaming-pattern
        // smoke test). No production code in DS3Lib imports NIO after the
        // Soto removal in Phase 16 Plan 05.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0")
    ],
    targets: [
        // Binary target wrapping the Rust core's UniFFI XCFramework.
        // The XCFramework exposes a single C-symbol Clang module named
        // `DS3CoreFFIFFI` (Headers/module.modulemap) covering both
        // ds3-ffi and ds3-models scaffolding outputs. See
        // `core/scripts/build-xcframework.sh` for the build pipeline.
        // Phase 16 Plan 05: Soto removed; swift-nio kept only for
        // `NIOCore.ByteBuffer` in StreamingIOTests.
        .binaryTarget(
            name: "DS3CoreFFIBinary",
            path: "../../core/out/DS3CoreFFI.xcframework"
        ),
        // Swift-glue target. Wraps the binary target and surfaces the
        // UniFFI-generated Swift bindings (Ds3SessionHandle, Account,
        // BucketInfo, free functions like conflictKey/getChallenge, etc.).
        // Consumers `import DS3CoreFFI` and get the full Swift surface.
        // Source files (ds3_models.swift, DS3CoreFFI.swift) are emitted
        // by `core/scripts/build-xcframework.sh` and synced here.
        .target(
            name: "DS3CoreFFI",
            dependencies: ["DS3CoreFFIBinary"],
            path: "Sources/DS3CoreFFI",
            // UniFFI-generated Swift bindings use shared mutable globals
            // (vtable pointers) that Swift 6 strict concurrency rejects.
            // Pin this target to Swift 5 mode to absorb the generated code
            // as-is; DS3Lib itself stays in Swift 6 mode and interacts with
            // the bindings via @unchecked Sendable bridge types.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            // The Rust core's transitive deps (hyper-util proxy detection,
            // aws-sdk auth, system_configuration, mac-keychain access) pull
            // symbols from several Apple system frameworks. Link them here
            // so dependent test/app targets don't have to repeat.
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CFNetwork")
            ]
        ),
        .target(
            name: "DS3Lib",
            dependencies: [
                "DS3CoreFFI",
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
                "DS3CoreFFI",
                .product(name: "NIOCore", package: "swift-nio")
            ],
            // Schema-parity fixtures (Phase 16 Plan 06 / D-25). The canonical
            // copies live at `core/ds3-models/tests/fixtures/`; this directory
            // mirrors them so SPM can expose them via `Bundle.module`. CI runs
            // a byte-equality check (build.yml "Schema parity fixture
            // byte-equality") to fail any drift between the two locations.
            // The dev-side sync helper is `core/scripts/sync-fixtures.sh`.
            resources: [
                .copy("Resources/fixtures")
            ]
        )
    ]
)
