#!/bin/bash
# Builds the DMG and publishes it as a GitHub release on hhazimee/ClaudeUsageBar.
# Usage: ./release.sh [tag]   (defaults to v<version from Info.plist>-multi.<build>)
set -euo pipefail
cd "$(dirname "$0")"

REPO="hhazimee/ClaudeUsageBar"
DMG="ClaudeUsageMulti-Installer.dmg"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
TAG="${1:-v${VERSION}-multi.${BUILD}}"

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first." >&2
    exit 1
fi
if [ "$(git branch --show-current)" != "main" ]; then
    echo "Release from main." >&2
    exit 1
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "$TAG already exists. Bump CFBundleVersion in Info.plist or pass a tag." >&2
    exit 1
fi

git push origin main
./build.sh
./create_dmg.sh
test -f "$DMG"

NOTES=$(cat <<EOF
Download **${DMG}**, open it and drag the app to Applications.

The app is not notarized by Apple, so macOS blocks the first launch. To allow it, either:
- open System Settings > Privacy & Security and click **Open Anyway**, or
- run \`xattr -dr com.apple.quarantine "/Applications/Claude Usage Multi.app"\`

## Changes
$(git log --pretty='- %s' "$(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD)"..HEAD 2>/dev/null | head -40)
EOF
)

gh release create "$TAG" "$DMG" -R "$REPO" --target main --title "Claude Usage Multi $TAG" --notes "$NOTES"
