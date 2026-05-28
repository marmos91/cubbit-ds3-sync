#!/bin/bash
# Build DS3CoreFFI.xcframework from the ds3-ffi Rust crate.
#
# Targets:
#   - aarch64-apple-darwin     (macOS Apple Silicon)
#   - aarch64-apple-ios        (iOS device)
#   - aarch64-apple-ios-sim  + (iOS Simulator ARM64)
#     x86_64-apple-ios         (iOS Simulator Intel) -> lipo fat binary
#
# Output:
#   core/out/DS3CoreFFI.xcframework
#   core/out/DS3CoreFFI.swift
#
# Usage:
#   ./core/scripts/build-xcframework.sh [--release|--debug]
#
# Prerequisites:
#   - Rust toolchain with all four Apple targets installed
#   - Xcode command-line tools (xcrun, xcodebuild, lipo)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CRATE_NAME="ds3_ffi"
FRAMEWORK_NAME="DS3CoreFFI"
CORE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${CORE_DIR}/out"
CARGO_MANIFEST="${CORE_DIR}/Cargo.toml"

# Ensure all cargo invocations resolve `Cargo.toml` from the workspace root.
# Xcode's Run Script Phase launches this script with cwd=$SRCROOT (apple/),
# and `cargo run --bin uniffi-bindgen` spawns a child that calls
# `cargo metadata` internally without `--manifest-path`. Without this cd
# the child fails with "could not find Cargo.toml" (Phase 16 Plan 03).
cd "${CORE_DIR}"

# Default to release builds; pass --debug for development.
BUILD_PROFILE="release"
CARGO_PROFILE_FLAG="--release"
if [[ "${1:-}" == "--debug" ]]; then
    BUILD_PROFILE="debug"
    CARGO_PROFILE_FLAG=""
fi

TARGETS=(
    "aarch64-apple-darwin"
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
    "x86_64-apple-ios"
)

echo "==> Building ds3-ffi for ${#TARGETS[@]} targets (${BUILD_PROFILE})..."

# ---------------------------------------------------------------------------
# Step 1: Build for all targets
# ---------------------------------------------------------------------------
for target in "${TARGETS[@]}"; do
    echo "    Building for ${target}..."
    # Set deployment targets for iOS/simulator to avoid __chkstk_darwin
    # linker errors from aws-lc-sys (macOS-only symbol).
    # aws-lc-sys requires cmake builder for iOS cross-compilation.
    # The default build uses macOS-only __chkstk_darwin symbol.
    case "${target}" in
        aarch64-apple-ios)
            export IPHONEOS_DEPLOYMENT_TARGET="17.0"
            export AWS_LC_SYS_CMAKE_BUILDER=1
            ;;
        aarch64-apple-ios-sim|x86_64-apple-ios)
            export IPHONEOS_DEPLOYMENT_TARGET="17.0"
            export AWS_LC_SYS_CMAKE_BUILDER=1
            ;;
        aarch64-apple-darwin)
            export MACOSX_DEPLOYMENT_TARGET="15.0"
            unset AWS_LC_SYS_CMAKE_BUILDER 2>/dev/null || true
            ;;
    esac
    cargo build --manifest-path "${CARGO_MANIFEST}" \
        --package ds3-ffi \
        ${CARGO_PROFILE_FLAG} \
        --target "${target}"
done

# ---------------------------------------------------------------------------
# Step 2: Generate Swift bindings via uniffi-bindgen
# ---------------------------------------------------------------------------
echo "==> Generating Swift bindings..."
cargo run --manifest-path "${CARGO_MANIFEST}" \
    --package ds3-ffi --bin uniffi-bindgen -- generate \
    --library "${CORE_DIR}/target/aarch64-apple-darwin/${BUILD_PROFILE}/lib${CRATE_NAME}.dylib" \
    --language swift \
    --out-dir "${OUT_DIR}"

# ---------------------------------------------------------------------------
# Step 3: Prepare headers directory.
#
# uniffi-bindgen emits a separate header + modulemap per scaffolding crate.
# We have TWO scaffolding crates (ds3-ffi and ds3-models). To keep a single
# `.binaryTarget(name: "DS3CoreFFI")` in SPM (which expects ONE module), we
# package both *FFI.h files into the XCFramework's Headers/ directory and
# write a single `module.modulemap` that declares one module
# `DS3CoreFFIFFI` containing BOTH headers. The Swift bindings already
# import `DS3CoreFFIFFI`; we rewrite `ds3_models.swift`'s
# `import ds3_modelsFFI` line to `import DS3CoreFFIFFI` (step 6) so both
# binding files compile against the same unified module.
#
# Phase 15's previous step-3 used a single-file loop that broke on first
# match, dropping one crate's C surface entirely (fixed in Plan 16-01).
# ---------------------------------------------------------------------------
echo "==> Preparing headers..."
mkdir -p "${OUT_DIR}/Headers"

# Copy ALL generated FFI headers (both ds3-ffi and ds3-models emit one each).
HEADER_COUNT=0
HEADER_BASENAMES=()
for hdr in "${OUT_DIR}"/*FFI.h; do
    if [[ -f "$hdr" ]]; then
        cp "$hdr" "${OUT_DIR}/Headers/"
        HEADER_BASENAMES+=("$(basename "$hdr")")
        HEADER_COUNT=$((HEADER_COUNT + 1))
    fi
done
if [[ "$HEADER_COUNT" -eq 0 ]]; then
    echo "ERROR: no *FFI.h files found in ${OUT_DIR}" >&2
    exit 1
fi
echo "    Packaged ${HEADER_COUNT} header file(s): ${HEADER_BASENAMES[*]}"

# Write a unified module.modulemap that exposes every *FFI.h under the
# single module `DS3CoreFFIFFI`. UniFFI's generated Swift bindings all
# `import DS3CoreFFIFFI` (after the sed rewrite in step 6).
{
    echo "module DS3CoreFFIFFI {"
    for base in "${HEADER_BASENAMES[@]}"; do
        echo "    header \"${base}\""
    done
    echo "    export *"
    echo "    use \"Darwin\""
    echo "    use \"_Builtin_stdbool\""
    echo "    use \"_Builtin_stdint\""
    echo "}"
} > "${OUT_DIR}/Headers/module.modulemap"
echo "    Wrote unified module.modulemap (module: DS3CoreFFIFFI)."

# ---------------------------------------------------------------------------
# Step 4: Create fat library for iOS simulator (arm64 + x86_64)
# ---------------------------------------------------------------------------
echo "==> Creating fat simulator library..."
mkdir -p "${OUT_DIR}/sim-fat"
lipo -create \
    "${CORE_DIR}/target/aarch64-apple-ios-sim/${BUILD_PROFILE}/lib${CRATE_NAME}.a" \
    "${CORE_DIR}/target/x86_64-apple-ios/${BUILD_PROFILE}/lib${CRATE_NAME}.a" \
    -output "${OUT_DIR}/sim-fat/lib${CRATE_NAME}.a"

# ---------------------------------------------------------------------------
# Step 5: Create XCFramework
# ---------------------------------------------------------------------------
echo "==> Creating XCFramework..."
rm -rf "${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"

xcodebuild -create-xcframework \
    -library "${CORE_DIR}/target/aarch64-apple-darwin/${BUILD_PROFILE}/lib${CRATE_NAME}.a" \
    -headers "${OUT_DIR}/Headers" \
    -library "${CORE_DIR}/target/aarch64-apple-ios/${BUILD_PROFILE}/lib${CRATE_NAME}.a" \
    -headers "${OUT_DIR}/Headers" \
    -library "${OUT_DIR}/sim-fat/lib${CRATE_NAME}.a" \
    -headers "${OUT_DIR}/Headers" \
    -output "${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"

# ---------------------------------------------------------------------------
# Step 6: Sync generated Swift bindings into the Apple package source tree.
#
# uniffi-bindgen emits one Swift file per scaffolding crate. We currently have
# TWO scaffolding crates (ds3-ffi and ds3-models), so uniffi-bindgen writes:
#
#   - ${OUT_DIR}/DS3CoreFFI.swift    (ds3-ffi exports: Ds3SessionHandle, free fns)
#   - ${OUT_DIR}/ds3_models.swift    (ds3-models types: Account, BucketInfo, ...)
#
# Both files are needed at compile time. We sync them into a sibling SPM
# target's source directory so `apple/DS3Lib/Package.swift` can declare a
# single `.target(name: "DS3CoreFFI")` that consumes both alongside the
# binary `.xcframework`. Phase 15's previous step-6 overwrote DS3CoreFFI.swift
# with ds3_models.swift (alphabetical loop ordering) — fixed in Plan 16-01.
# ---------------------------------------------------------------------------
SWIFT_TARGET_DIR="${CORE_DIR}/../apple/DS3Lib/Sources/DS3CoreFFI"
mkdir -p "${SWIFT_TARGET_DIR}"

for swift_basename in "${FRAMEWORK_NAME}.swift" "ds3_models.swift"; do
    src="${OUT_DIR}/${swift_basename}"
    dest="${SWIFT_TARGET_DIR}/${swift_basename}"
    if [[ -f "$src" ]]; then
        # Rewrite per-crate `import <crate>FFI` lines AND the surrounding
        # `#if canImport(<crate>FFI)` guard to the unified module name
        # `DS3CoreFFIFFI` (declared by Headers/module.modulemap in step 3,
        # covering both header files). Without this the ds3_models.swift
        # bindings would try to import a top-level module `ds3_modelsFFI`
        # that doesn't exist, and the canImport guard would short-circuit
        # the inner import.
        sed -e 's/^import ds3_modelsFFI$/import DS3CoreFFIFFI/' \
            -e 's/canImport(ds3_modelsFFI)/canImport(DS3CoreFFIFFI)/g' \
            "$src" > "$dest"
    else
        echo "WARNING: expected generated Swift file not found: $src" >&2
    fi
done

echo "==> Done!"
echo "    XCFramework:  ${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"
echo "    Swift glue:   ${SWIFT_TARGET_DIR}/{${FRAMEWORK_NAME}.swift, ds3_models.swift}"
