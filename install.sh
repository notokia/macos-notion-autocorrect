#!/bin/zsh
set -e

REPO="${NOTION_AUTOCORRECT_REPO:-notokia/macos-notion-autocorrect}"
DMG_URL="https://github.com/$REPO/releases/latest/download/NotionAutocorrect.dmg"
TMP_DMG="/tmp/NotionAutocorrect.dmg"
MOUNT_DIR="/tmp/NotionAutocorrectMount"

echo "Downloading NotionAutocorrect..."
curl -fsSL "$DMG_URL" -o "$TMP_DMG"

echo "Mounting installer..."
mkdir -p "$MOUNT_DIR"
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

echo "Installing to /Applications/NotionAutocorrect.app..."
pkill -x "NotionAutocorrect" 2>/dev/null || true
rm -rf /Applications/NotionAutocorrect.app
cp -R "$MOUNT_DIR/NotionAutocorrect.app" /Applications/NotionAutocorrect.app

echo "Clearing macOS quarantine flag..."
xattr -cr /Applications/NotionAutocorrect.app 2>/dev/null || true

hdiutil detach "$MOUNT_DIR" -quiet
rm -rf "$TMP_DMG" "$MOUNT_DIR"

echo "Launching NotionAutocorrect..."
open -a /Applications/NotionAutocorrect.app
echo "Done! Grant Accessibility permission in System Settings when prompted."
