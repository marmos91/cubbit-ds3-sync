#!/usr/bin/env bash
# Sync schema-parity JSON fixtures from `core/ds3-models/tests/fixtures/`
# (the Rust serde source of truth) into the Swift test target's resources
# directory at `apple/DS3Lib/Tests/DS3LibTests/Resources/fixtures/`.
#
# Both copies are committed to git. CI runs a byte-equality diff (see
# `.github/workflows/build.yml` "Schema parity fixture byte-equality" step)
# to fail any drift between the two locations. This script is the dev
# escape hatch when you edit a fixture and need to push the change to the
# Swift side before committing.
#
# Why duplicates instead of SPM path-traversal: Swift Package Manager
# rejects `.copy("../../../core/...")` paths outside the package root
# (verified against SPM 5.10/6.0). Committing duplicates + a CI byte-
# equality gate gives us a single logical source of truth (the Rust files)
# without fighting the SPM sandbox.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SRC_DIR="$REPO_ROOT/core/ds3-models/tests/fixtures"
DST_DIR="$REPO_ROOT/apple/DS3Lib/Tests/DS3LibTests/Resources/fixtures"

if [ ! -d "$SRC_DIR" ]; then
    echo "FATAL: source fixtures directory not found: $SRC_DIR" >&2
    exit 1
fi

mkdir -p "$DST_DIR"

for src in "$SRC_DIR"/*.json; do
    name="$(basename "$src")"
    dst="$DST_DIR/$name"
    cp "$src" "$dst"
    echo "synced: $name"
done

echo "OK: synced fixtures from $SRC_DIR to $DST_DIR"
