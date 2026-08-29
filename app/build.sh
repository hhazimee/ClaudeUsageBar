#!/bin/bash

# Build script for ClaudeUsageBar

echo "Building ClaudeUsageBar..."

# Create fresh build directory (delete any stale build to avoid accumulated xattrs
# from prior signs, which can cause "resource fork / detritus" errors on codesign).
rm -rf build
mkdir -p build

# Create app bundle structure first
APP_NAME="Claude Usage Multi.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp Info.plist "$APP_PATH/Contents/"

# Create icon if it doesn't exist
if [ ! -f "ClaudeUsageBar.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null 2>&1
fi

# Copy icon to Resources
if [ -f "ClaudeUsageBar.icns" ]; then
    cp ClaudeUsageBar.icns "$APP_PATH/Contents/Resources/"
    # Update Info.plist to reference icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ClaudeUsageBar" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ClaudeUsageBar" "$APP_PATH/Contents/Info.plist"
fi

# Compile the Swift app for arm64
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    ClaudeUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos12.0

# Compile for x86_64 (Intel)
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" \
    ClaudeUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target x86_64-apple-macos12.0

# Create universal binary
lipo -create -output "$APP_PATH/Contents/MacOS/ClaudeUsageBar" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Clean up individual arch binaries
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64"
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Create PkgInfo file
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Set proper permissions first
chmod 755 "$APP_PATH/Contents/MacOS/ClaudeUsageBar"

# Clean any "detritus" that codesign rejects: extended attributes, ._files, .DS_Store
xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null
dot_clean "$APP_PATH" 2>/dev/null

# Sign the bundle. Release builds need a real Developer ID (ad-hoc signatures fail
# notarization), but a local build just needs to launch, so fall back to ad-hoc
# unless RELEASE=1 is set.
DEVELOPER_ID="${SIGN_IDENTITY:-Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)}"

if codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_PATH" 2>/dev/null; then
    echo "✅ App signed with Developer ID"
    if codesign --verify --verbose=2 "$APP_PATH" 2>&1 | grep -q "valid on disk"; then
        echo "✅ Signature verified"
    else
        echo "❌ Signature verification failed — fix before shipping" >&2
        exit 1
    fi
elif [ "${RELEASE:-0}" = "1" ]; then
    echo "❌ Developer ID signing failed. NOT falling back to ad-hoc (would break notarization)." >&2
    echo "   Fix the cause above (often: stale xattrs / ._files / cert not in keychain) and re-run." >&2
    exit 1
else
    echo "⚠️  No Developer ID cert found, signing ad-hoc for local use."
    echo "   Set RELEASE=1 to make missing signing a hard failure."
    codesign --force --deep --sign - "$APP_PATH" || exit 1
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"

# Install to /Applications and launch from there. macOS only grants notification
# permission to apps registered with Launch Services, and the FIRST launch of a
# bundle id from an unregistered location (like build/) permanently marks it
# denied. So never open the build/ copy directly.
INSTALL_PATH="/Applications/$APP_NAME"
if [ "${INSTALL:-1}" = "1" ]; then
    echo "Installing to $INSTALL_PATH..."
    pkill -f "$INSTALL_PATH/Contents/MacOS" 2>/dev/null
    sleep 1
    rm -rf "$INSTALL_PATH"
    cp -R "$APP_PATH" "/Applications/"
    xattr -cr "$INSTALL_PATH"
    codesign --force --deep --sign - "$INSTALL_PATH" 2>/dev/null
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_PATH"
    echo "Launching from /Applications..."
    open "$INSTALL_PATH"
else
    echo "INSTALL=0 set; not installing. Do not open build/ directly (breaks notifications)."
fi
