#!/bin/bash
# Builds MacMate.app into ./dist using only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="dist/MacMate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacMate "$APP/Contents/MacOS/MacMate"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Packaging/AppIcon.icns ]; then
    swift Packaging/make-icon.swift Packaging/AppIcon.iconset
    iconutil -c icns Packaging/AppIcon.iconset -o Packaging/AppIcon.icns
fi
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier com.macmate.app "$APP"
echo "Built $APP"
