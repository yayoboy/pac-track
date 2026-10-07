#!/bin/sh
# Builds build/PacTrack.app (release, ad-hoc signed) without Xcode.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product PacTrack
APP=build/PacTrack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PacTrack "$APP/Contents/MacOS/PacTrack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "$APP"
