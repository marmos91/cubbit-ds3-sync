#!/usr/bin/env bash
# generate-appcast.sh — Generates or updates appcast.xml for Sparkle auto-updates.
#
# Usage: ./scripts/generate-appcast.sh <version> <dmg-url> <dmg-path> <signature> <appcast-file>
#
# Arguments:
#   version      — Marketing version (e.g. "2.1.0")
#   dmg-url      — Public download URL for the DMG
#   dmg-path     — Local path to the DMG (for computing file size)
#   signature    — EdDSA signature string from `sign_update`
#   appcast-file — Path to appcast.xml to create/update

set -euo pipefail

VERSION="$1"
DMG_URL="$2"
DMG_PATH="$3"
SIGNATURE="$4"
APPCAST_FILE="$5"

LENGTH=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat --printf="%s" "$DMG_PATH")
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# XML-escape values that could contain special characters
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
VERSION=$(xml_escape "$VERSION")
DMG_URL=$(xml_escape "$DMG_URL")

ITEM=$(cat <<ITEM_EOF
            <item>
                <title>Version ${VERSION}</title>
                <pubDate>${PUB_DATE}</pubDate>
                <enclosure
                    url="${DMG_URL}"
                    sparkle:version="${VERSION}"
                    sparkle:shortVersionString="${VERSION}"
                    sparkle:edSignature="${SIGNATURE}"
                    length="${LENGTH}"
                    type="application/octet-stream"
                />
            </item>
ITEM_EOF
)

if [ -f "$APPCAST_FILE" ]; then
    # Insert new item before the closing </channel> tag
    # Use a temp file for portability (BSD sed vs GNU sed)
    TEMP_FILE=$(mktemp)
    awk -v item="$ITEM" '/<\/channel>/ { print item } { print }' "$APPCAST_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$APPCAST_FILE"
else
    cat > "$APPCAST_FILE" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Cubbit DS3 Drive</title>
        <link>https://github.com/cubbit/cubbit-ds3-drive</link>
        <description>Cubbit DS3 Drive updates</description>
        <language>en</language>
${ITEM}
    </channel>
</rss>
APPCAST_EOF
fi

echo "Appcast updated: ${APPCAST_FILE} (version ${VERSION})"
