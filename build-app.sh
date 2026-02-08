#!/bin/bash
set -e

# Build the executable
swift build -c release

# Set up .app bundle structure
APP="PhotoRenamer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy executable
cp .build/release/PhotoRenamer "$APP/Contents/MacOS/PhotoRenamer"

# Copy Info.plist and icon
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Built $APP successfully."
echo "You can now move it to /Applications or double-click to run."

# Build DMG installer
echo ""
echo "Creating DMG installer..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DMG_NAME="PhotoRenamer.dmg"
DMG_RW="PhotoRenamer_rw.dmg"
VOL_NAME="PhotoRenamer"
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
        set position of item "PhotoRenamer.app" of container window to {165, 200}
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

echo "Created $DMG_NAME — distribute this file for installation."
