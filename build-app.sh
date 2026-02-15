#!/bin/bash
set -e

# Parse arguments
SIGN=false
TEAM_ID="C6CJGU3CFS"
DEVELOPER_ID=""
APPLE_ID=""
APP_PASSWORD=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --sign) SIGN=true ;;
        --team-id) TEAM_ID="$2"; shift ;;
        --developer-id) DEVELOPER_ID="$2"; shift ;;
        --apple-id) APPLE_ID="$2"; shift ;;
        --app-password) APP_PASSWORD="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Build the executable
swift build -c release

# Set up .app bundle structure
APP="PhoDoo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy executable
cp .build/release/PhoDoo "$APP/Contents/MacOS/PhoDoo"

# Copy Info.plist and icon
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Copy entitlements into bundle for reference
if [ -f PhoDoo.entitlements ]; then
    cp PhoDoo.entitlements "$APP/Contents/Resources/PhoDoo.entitlements"
fi

echo "Built $APP successfully."

# Code signing
if [ "$SIGN" = true ]; then
    echo ""
    echo "Signing app bundle..."

    if [ -z "$DEVELOPER_ID" ]; then
        # Auto-detect Developer ID certificate
        DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
        if [ -z "$DEVELOPER_ID" ]; then
            echo "Error: No Developer ID Application certificate found."
            echo "Install one from developer.apple.com or specify with --developer-id"
            exit 1
        fi
        echo "Using certificate: $DEVELOPER_ID"
    fi

    codesign --force --options runtime \
        --entitlements PhoDoo.entitlements \
        --sign "$DEVELOPER_ID" \
        --timestamp \
        "$APP"

    echo "Signed successfully."

    # Verify signature
    codesign --verify --verbose=2 "$APP"
    echo "Signature verified."
fi

echo ""
echo "You can now move it to /Applications or double-click to run."

# Build DMG installer
echo ""
echo "Creating DMG installer..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DMG_NAME="PhoDoo.dmg"
DMG_RW="PhoDoo_rw.dmg"
VOL_NAME="PhoDoo"
DMG_TEMP="dmg_staging"

# Generate background image if needed
if [ ! -f dmg_background.png ]; then
    echo "Generating DMG background..."
    swift "$SCRIPT_DIR/create_dmg_background.swift"
fi

rm -rf "$DMG_TEMP" "$DMG_NAME" "$DMG_RW"
mkdir -p "$DMG_TEMP"
cp -R "$APP" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

# Create a read-write DMG so we can style it
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDRW \
    -size 200m \
    "$DMG_RW"

rm -rf "$DMG_TEMP"

# Mount it
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_RW" | grep "/Volumes/$VOL_NAME" | awk '{print $3}')
echo "Mounted at: $MOUNT_DIR"

# Add background image
mkdir -p "$MOUNT_DIR/.background"
cp dmg_background.png "$MOUNT_DIR/.background/background.png"

# Use AppleScript to set window appearance
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "PhoDoo.app" of container window to {165, 200}
        set position of item "Applications" of container window to {495, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Ensure Finder writes .DS_Store
sync
sleep 2

# Detach
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
rm -f "$DMG_RW"

# Sign and notarize the DMG if requested
if [ "$SIGN" = true ]; then
    echo ""
    echo "Signing DMG..."
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG_NAME"

    if [ -n "$APPLE_ID" ] && [ -n "$APP_PASSWORD" ]; then
        echo "Submitting for notarization..."
        xcrun notarytool submit "$DMG_NAME" \
            --apple-id "$APPLE_ID" \
            --password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait

        echo "Stapling notarization ticket..."
        xcrun stapler staple "$DMG_NAME"
        echo "Notarization complete."
    else
        echo "Skipping notarization (provide --apple-id and --app-password to notarize)"
    fi
fi

echo "Created $DMG_NAME — distribute this file for installation."
