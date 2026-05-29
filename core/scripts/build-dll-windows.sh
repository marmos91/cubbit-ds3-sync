#!/usr/bin/env bash
# Build ds3_ffi.dll for Windows from the ds3-ffi Rust crate (POSIX shell).
#
# Targets (per 17-CONTEXT.md D-06):
#   - x86_64-pc-windows-msvc   -> runtimes/win-x64/native/ds3_ffi.dll
#   - aarch64-pc-windows-msvc  -> runtimes/win-arm64/native/ds3_ffi.dll
#
# Artifact name: ds3_ffi.dll (NOT ds3_core.dll — see 17-RESEARCH §Pitfall 6).
# The companion PowerShell script (build-dll-windows.ps1) produces the same
# layout natively on a Windows host.
#
# Usage:
#   ./core/scripts/build-dll-windows.sh [--profile release|debug]
#
# Prerequisites (darwin / Linux cross-compile):
#   - Rust toolchain with both Windows MSVC targets installed:
#       rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc
#   - A linker capable of producing PE/COFF objects.
#     On macOS/Linux the conventional path is `lld-link` (from LLVM) or the
#     `mingw-w64` toolchain. Install with: `brew install llvm` (provides
#     `lld-link`) or `brew install mingw-w64`. Without one of those linkers
#     the cargo build will fail at the link step — this is expected on a
#     stock macOS box; CI runs this script on a windows-latest runner where
#     the MSVC toolchain is present.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DLL_NAME="ds3_ffi.dll"
CORE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_BASE="${CORE_DIR}/out/windows"
CARGO_MANIFEST="${CORE_DIR}/Cargo.toml"

cd "${CORE_DIR}"

BUILD_PROFILE="release"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            BUILD_PROFILE="$2"
            shift 2
            ;;
        --debug)
            BUILD_PROFILE="debug"
            shift
            ;;
        --release)
            BUILD_PROFILE="release"
            shift
            ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

case "${BUILD_PROFILE}" in
    release) CARGO_PROFILE_FLAG="--release" ;;
    debug)   CARGO_PROFILE_FLAG="" ;;
    *)
        echo "Unsupported profile: ${BUILD_PROFILE} (expected 'release' or 'debug')" >&2
        exit 2
        ;;
esac

# Map cargo target triples -> NuGet runtime identifiers (D-06 layout).
TARGETS=(
    "x86_64-pc-windows-msvc:win-x64"
    "aarch64-pc-windows-msvc:win-arm64"
)

echo "==> Building ${DLL_NAME} for ${#TARGETS[@]} Windows targets (${BUILD_PROFILE})..."
echo "    Artifact name: ${DLL_NAME} (canonical per 17-RESEARCH Pitfall 6)"

# ---------------------------------------------------------------------------
# Step 1: Ensure Windows rustup targets are installed.
# ---------------------------------------------------------------------------
echo "==> Ensuring rustup targets are installed..."
for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"
    rustup target add "${triple}" >/dev/null
done

# ---------------------------------------------------------------------------
# Step 2: Build the DLL for each Windows target.
# ---------------------------------------------------------------------------
for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"
    rid="${entry##*:}"
    echo "==> cargo build --target ${triple} (${rid})"
    cargo build --manifest-path "${CARGO_MANIFEST}" \
        --package ds3-ffi \
        ${CARGO_PROFILE_FLAG} \
        --target "${triple}"

    SRC_DLL="${CORE_DIR}/target/${triple}/${BUILD_PROFILE}/${DLL_NAME}"
    DEST_DIR="${OUT_BASE}/runtimes/${rid}/native"
    DEST_DLL="${DEST_DIR}/${DLL_NAME}"

    if [[ ! -f "${SRC_DLL}" ]]; then
        echo "FATAL: expected DLL not found at ${SRC_DLL}" >&2
        exit 1
    fi

    mkdir -p "${DEST_DIR}"
    cp "${SRC_DLL}" "${DEST_DLL}"
done

# ---------------------------------------------------------------------------
# Step 3: Summary table (triple -> size -> sha256).
# ---------------------------------------------------------------------------
echo ""
echo "==> Build complete. Artifacts:"
printf "    %-30s %-15s %-12s %s\n" "TRIPLE" "RID" "SIZE" "SHA256"
for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"
    rid="${entry##*:}"
    DEST_DLL="${OUT_BASE}/runtimes/${rid}/native/${DLL_NAME}"

    if [[ ! -f "${DEST_DLL}" ]]; then
        echo "FATAL: ${DEST_DLL} missing after build" >&2
        exit 1
    fi

    size_bytes=$(wc -c < "${DEST_DLL}" | tr -d ' ')
    sha=$(shasum -a 256 "${DEST_DLL}" | awk '{print $1}')
    printf "    %-30s %-15s %-12s %s\n" "${triple}" "${rid}" "${size_bytes}" "${sha}"
done

echo ""
echo "==> Layout: ${OUT_BASE}/runtimes/win-x64/native/${DLL_NAME}"
echo "             ${OUT_BASE}/runtimes/win-arm64/native/${DLL_NAME}"
