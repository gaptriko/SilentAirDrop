#!/bin/bash

# SilentAirDrop Terminal Installer

echo "🚀 Downloading SilentAirDrop..."

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Download the latest DMG release from GitHub
curl -sL -o SilentAirDrop.dmg "https://github.com/gaptriko/SilentAirDrop/releases/latest/download/SilentAirDrop.dmg"

if [ ! -f "SilentAirDrop.dmg" ]; then
    echo "❌ Download failed. Make sure the release exists on GitHub."
    exit 1
fi

echo "💽 Mounting DMG..."
# Mount the DMG without opening a Finder window
hdiutil attach SilentAirDrop.dmg -nobrowse -mountpoint /Volumes/SilentAirDrop

echo "📂 Installing to /Applications..."
# Remove old version if exists
rm -rf /Applications/SilentAirDrop.app
# Copy the app to Applications folder
cp -R /Volumes/SilentAirDrop/SilentAirDrop.app /Applications/

echo "🧹 Cleaning up..."
# Unmount the DMG
hdiutil detach /Volumes/SilentAirDrop
cd ~
rm -rf "$TEMP_DIR"

echo "✨ Opening SilentAirDrop..."
# Open the app (this will trigger the Accessibility prompts)
open /Applications/SilentAirDrop.app

echo "✅ Installation complete!"
