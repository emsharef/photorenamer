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
