#!/bin/zsh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
    SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
    SDK="$(xcrun --show-sdk-path)"
fi
APP_BUNDLE="/Applications/NotionAutocorrect.app"

pkill -x "NotionAutocorrect" 2>/dev/null || true

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$DIR/AppIcon.icns" ]; then
    cp "$DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

clang -isysroot "$SDK" \
      -arch arm64 -arch x86_64 \
      -mmacosx-version-min=13.0 \
      -O2 -fobjc-arc \
      -framework AppKit \
      -framework ApplicationServices \
      "$DIR/main.m" \
      -o "$APP_BUNDLE/Contents/MacOS/NotionAutocorrect"

codesign --force --deep --sign - "$APP_BUNDLE"
tccutil reset Accessibility com.bernardo.NotionAutocorrect 2>/dev/null || true
echo "Build universal (arm64 + x86_64) concluído com sucesso em: $APP_BUNDLE"
