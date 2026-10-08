#!/bin/sh
# Builds build/PacTrack.app (release, icon, ad-hoc signed) without Xcode.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product PacTrack
APP=build/PacTrack.app
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PacTrack "$APP/Contents/MacOS/PacTrack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -O scripts/make-icon.swift -o .build/make-icon
.build/make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP"
codesign --verify --strict "$APP"
echo "$APP"
