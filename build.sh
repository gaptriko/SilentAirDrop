#!/bin/bash

# SilentAirDrop Build Script

APP_NAME="SilentAirDrop"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"

echo "📦 Building $APP_NAME..."

# 1. Create Bundle Structure
rm -rf "$APP_BUNDLE"
rm -f "$DMG_NAME"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 2. Copy Plist & Icon
cp Info.plist "$APP_BUNDLE/Contents/"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# 3. Compile Universal Binary
echo "🔨 Compiling Swift code..."

# Compile for arm64
echo "  ▸ Compiling arm64..."
swiftc main.swift -o "SilentAirDrop_arm64" \
    -target arm64-apple-macos13.0 \
    -O -framework AppKit -framework Foundation -framework CoreGraphics -framework ServiceManagement
    
# Compile for x86_64
echo "  ▸ Compiling x86_64..."
swiftc main.swift -o "SilentAirDrop_x86" \
    -target x86_64-apple-macos13.0 \
    -O -framework AppKit -framework Foundation -framework CoreGraphics -framework ServiceManagement

# Combine into Universal Binary
echo "  ▸ Creating Universal Binary with lipo..."
lipo -create "SilentAirDrop_arm64" "SilentAirDrop_x86" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
rm "SilentAirDrop_arm64" "SilentAirDrop_x86"

if [ $? -ne 0 ]; then
    echo "❌ Compilation or Lipo failed."
    exit 1
fi

# 4. Clean extended attributes (Required for codesign)
echo "🧹 Cleaning extended attributes..."
xattr -cr "$APP_BUNDLE"

# 5. Ad-hoc Sign the App (Crucial for modern macOS)
echo "🔐 Ad-hoc signing the app..."
codesign --force --deep --sign - "$APP_BUNDLE"

# 6. Refresh icon cache
touch "$APP_BUNDLE"

# 6. Create DMG
echo "🗜 Preparing DMG folder..."
DMG_TEMP="DMG_TEMP"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"
cp -R "$APP_BUNDLE" "$DMG_TEMP/"
ln -s /Applications "$DMG_TEMP/Applications"

echo "🗜 Creating DMG image..."
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TEMP" -ov -format UDZO "$DMG_NAME" > /dev/null
rm -rf "$DMG_TEMP"

echo "✅ Success! Built ${APP_BUNDLE} and ${DMG_NAME}"
