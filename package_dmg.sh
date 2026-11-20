#!/bin/zsh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/build.sh"

STAGING="/tmp/notion_autocorrect_dmg"
DIST_DIR="$DIR/dist"
DMG_PATH="$DIST_DIR/NotionAutocorrect.dmg"

rm -rf "$STAGING"
mkdir -p "$STAGING" "$DIST_DIR"

cp -R "/Applications/NotionAutocorrect.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "NotionAutocorrect" \
               -srcfolder "$STAGING" \
               -ov -format UDZO \
               "$DMG_PATH"

rm -rf "$STAGING"
echo "Instalador DMG gerado em: $DMG_PATH"
