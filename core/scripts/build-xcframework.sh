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
# Step 3: Prepare headers directory
# ---------------------------------------------------------------------------
echo "==> Preparing headers..."
mkdir -p "${OUT_DIR}/Headers"

# Copy the generated header.
if [[ -f "${OUT_DIR}/${CRATE_NAME}FFI.h" ]]; then
    cp "${OUT_DIR}/${CRATE_NAME}FFI.h" "${OUT_DIR}/Headers/"
elif [[ -f "${OUT_DIR}/${FRAMEWORK_NAME}FFI.h" ]]; then
    cp "${OUT_DIR}/${FRAMEWORK_NAME}FFI.h" "${OUT_DIR}/Headers/"
fi

# Rename the modulemap to module.modulemap (required by XCFramework/Clang).
# Per Pitfall 2: UniFFI generates {name}FFI.modulemap but XCFramework needs
# module.modulemap.
for mm in "${OUT_DIR}"/*FFI.modulemap "${OUT_DIR}"/*.modulemap; do
    if [[ -f "$mm" ]]; then
        cp "$mm" "${OUT_DIR}/Headers/module.modulemap"
        break
    fi
done

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
# Step 6: Copy generated Swift file alongside XCFramework
# ---------------------------------------------------------------------------
for swift_file in "${OUT_DIR}"/*.swift; do
    if [[ -f "$swift_file" && "$(basename "$swift_file")" != "${FRAMEWORK_NAME}.swift" ]]; then
        cp "$swift_file" "${OUT_DIR}/${FRAMEWORK_NAME}.swift"
        break
    fi
done

echo "==> Done!"
echo "    XCFramework: ${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"
echo "    Swift file:  ${OUT_DIR}/${FRAMEWORK_NAME}.swift"
