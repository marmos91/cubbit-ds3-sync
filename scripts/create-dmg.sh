#!/usr/bin/env bash
set -euo pipefail

# Usage: create-dmg.sh <app-path> <output-dmg-path> [volume-name]
# Example: create-dmg.sh "build/Cubbit DS3 Drive.app" "build/Cubbit-DS3-Drive-1.5.0.dmg" "Cubbit DS3 Drive"

APP_PATH="${1:?Usage: create-dmg.sh <app-path> <output-dmg-path> [volume-name]}"
OUTPUT_DMG="${2:?Usage: create-dmg.sh <app-path> <output-dmg-path> [volume-name]}"
VOLUME_NAME="${3:-Cubbit DS3 Drive}"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH" >&2
    exit 1
fi

command -v create-dmg >/dev/null 2>&1 || {
    echo "Error: create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
}

rm -f "$OUTPUT_DMG"

APP_NAME=$(basename "$APP_PATH")

create-dmg \
    --volname "$VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 160 \
    --icon "$APP_NAME" 160 185 \
    --hide-extension "$APP_NAME" \
    --app-drop-link 500 185 \
    "$OUTPUT_DMG" \
    "$APP_PATH"
